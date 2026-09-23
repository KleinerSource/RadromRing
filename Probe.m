#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

#import <substrate.h>

#import "core/RRPreferences.h"
#import "core/RRSelection.h"

/*
 * The incoming-call ringtone is resolved through ToneLibrary. Each ring creates a
 * TLAlert of type TLAlertTypeIncomingCall; when its configuration carries no explicit
 * toneIdentifier, ToneLibrary falls back to TLToneManager's current default.
 * Contact-specific ringtones arrive as explicit identifiers, so filling in only the
 * missing identifier keeps them intact, including when a contact's tone equals the
 * default. Every alert gets a fresh pick; the default lookup is also hooked in case
 * the ring is resolved without going through alertWithConfiguration:.
 */

typedef id (*RRCurrentToneForTypeTopicIMP)(id, SEL, long long, id);
typedef id (*RRCurrentToneForTypeIMP)(id, SEL, long long);
typedef id (*RRAlertWithConfigurationIMP)(id, SEL, id);
typedef id (*RRInitIMP)(id, SEL);

static RRCurrentToneForTypeTopicIMP RROriginalCurrentToneForTypeTopic;
static RRCurrentToneForTypeIMP RROriginalCurrentToneForType;
static RRAlertWithConfigurationIMP RROriginalAlertWithConfiguration;
static RRInitIMP RROriginalCallInit;

static BOOL RRInstallPollScheduled;
static NSUInteger RRInstallPollCount;
static BOOL RRIsInCallService;
static __thread BOOL RRResolvingTone;
/* Tone chosen for the alert being created on this thread (unretained; owned by the hook frame). */
static __thread void *RRAlertTone;

static const long long RRAlertTypeIncomingCall = 1;
static const int RRCallStatusRinging = 4;
/* Default lookups this soon after a pick belong to the same ring. Not extended by reuse. */
static const CFAbsoluteTime RRSameRingWindow = 2.0;
static const NSUInteger RRMaxInstallPolls = 240;

static NSObject *RRStateLock;
static NSString *RRLastToneIdentifier;
static CFAbsoluteTime RRLastPickTime;
static NSHashTable *RRTrackedCalls;

static NSString *RRStringValue(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

static id RRCallObjectGetter(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static BOOL RRCallBooleanGetter(id object, NSString *selectorName, BOOL *available) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        if (available != NULL) *available = NO;
        return NO;
    }
    if (available != NULL) *available = YES;
    BOOL (*sendMessage)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static long long RRIntegerGetter(id object, NSString *selectorName, BOOL *available) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        if (available != NULL) *available = NO;
        return 0;
    }
    if (available != NULL) *available = YES;
    long long (*sendMessage)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static NSString *RRUUIDString(id value) {
    if ([value isKindOfClass:NSUUID.class]) return [(NSUUID *)value UUIDString];
    return RRStringValue(value).uppercaseString;
}

#pragma mark - Preferences

static NSDictionary *RRPreferences(void) {
    CFStringRef domain = CFSTR(RR_PREFERENCES_DOMAIN);
    CFPreferencesAppSynchronize(domain);
    CFArrayRef keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys != NULL) {
        CFDictionaryRef values = CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser,
                                                           kCFPreferencesAnyHost);
        CFRelease(keys);
        NSDictionary *result = CFBridgingRelease(values);
        if (result.count > 0) return result;
    }

    /* Sandboxed call processes may be denied the cfprefsd domain but not the file. */
    return [NSDictionary dictionaryWithContentsOfFile:@RR_PREFERENCES_PATH] ?: @{};
}

#pragma mark - Tone catalog

static id RRToneManager(void) {
    static id sharedManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/ToneLibrary.framework/ToneLibrary", RTLD_LAZY);
        Class managerClass = objc_getClass("TLToneManager");
        SEL sharedSelector = NSSelectorFromString(@"sharedToneManager");
        if (managerClass != Nil && [managerClass respondsToSelector:sharedSelector]) {
            id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            sharedManager = sendMessage(managerClass, sharedSelector);
        }
    });
    return sharedManager;
}

static BOOL RRToneIdentifierIsValid(id manager, NSString *identifier) {
    SEL selector = NSSelectorFromString(@"toneWithIdentifierIsValid:");
    if (manager == nil || identifier == nil || ![manager respondsToSelector:selector]) return NO;
    BOOL (*sendMessage)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return sendMessage(manager, selector, identifier);
}

static void RRAddValidTones(NSMutableOrderedSet<NSString *> *pool, id configured, id manager) {
    if (![configured isKindOfClass:NSArray.class]) return;
    for (id item in (NSArray *)configured) {
        NSString *identifier = RRStringValue(item);
        if (identifier != nil && RRToneIdentifierIsValid(manager, identifier)) [pool addObject:identifier];
    }
}

#pragma mark - Ringing call and SIM slot

static id RRHookCallInit(id self, SEL selector) {
    id call = RROriginalCallInit(self, selector);
    if (call != nil) {
        @synchronized (RRStateLock) {
            [RRTrackedCalls addObject:call];
        }
    }
    return call;
}

static BOOL RRCallIsRingingIncoming(id call) {
    BOOL hasIncoming = NO;
    if (!RRCallBooleanGetter(call, @"isIncoming", &hasIncoming) || !hasIncoming) return NO;
    BOOL hasStatus = NO;
    /* TUCallStatus is a 32-bit int; the upper half of the register is undefined. */
    int status = (int)RRIntegerGetter(call, @"status", &hasStatus);
    return !hasStatus || status == RRCallStatusRinging;
}

static id RRRingingIncomingCall(void) {
    NSMutableArray *candidates = [NSMutableArray array];

    /* TUCallCenter is a client of callservicesd; only use it outside that daemon. */
    if (RRIsInCallService) {
        Class centerClass = objc_getClass("TUCallCenter");
        id center = [centerClass respondsToSelector:NSSelectorFromString(@"sharedInstance")]
            ? RRCallObjectGetter(centerClass, @"sharedInstance") : nil;
        id incoming = RRCallObjectGetter(center, @"incomingCall");
        if (incoming != nil) [candidates addObject:incoming];
        id current = RRCallObjectGetter(center, @"currentCalls");
        if ([current isKindOfClass:NSArray.class]) [candidates addObjectsFromArray:current];
    }

    @synchronized (RRStateLock) {
        [candidates addObjectsFromArray:RRTrackedCalls.allObjects];
    }

    for (id call in candidates) {
        if (RRCallIsRingingIncoming(call)) return call;
    }
    return nil;
}

static BOOL RRCallIsCellular(id call) {
    BOOL hasVoIP = NO;
    if (RRCallBooleanGetter(call, @"isVoIPCall", &hasVoIP) && hasVoIP) return NO;
    id provider = RRCallObjectGetter(call, @"provider");
    BOOL hasTelephony = NO;
    BOOL telephony = RRCallBooleanGetter(provider, @"isTelephonyProvider", &hasTelephony);
    return !hasTelephony || telephony;
}

/* Returns 1 or 2, or 0 when the call's SIM cannot be matched to a known slot. */
static NSInteger RRSIMSlotForCall(id call, NSDictionary *preferences) {
    NSDictionary *accounts = preferences[RR_PREFERENCE_SIM_ACCOUNTS_KEY];
    if (call == nil || ![accounts isKindOfClass:NSDictionary.class] || accounts.count == 0) return 0;

    id identity = RRCallObjectGetter(call, @"localSenderIdentity");
    NSArray *values = @[
        RRCallObjectGetter(call, @"localSenderIdentityAccountUUID") ?: NSNull.null,
        RRCallObjectGetter(call, @"localSenderIdentityUUID") ?: NSNull.null,
        RRCallObjectGetter(identity, @"accountUUID") ?: NSNull.null,
        RRCallObjectGetter(identity, @"UUID") ?: NSNull.null,
    ];
    for (id value in values) {
        NSString *key = RRUUIDString(value);
        if (key == nil) continue;
        NSInteger slot = [accounts[key] integerValue];
        if (slot == 1 || slot == 2) return slot;
    }
    return 0;
}

#pragma mark - Selection

static uint32_t RRBoundedRandom(uint32_t upperBound, void *context) {
    (void)context;
    return arc4random_uniform(upperBound);
}

/* Caller holds RRStateLock. */
static NSString *RRPickNewTone(NSArray<NSString *> *pool) {
    if (pool.count == 0 || pool.count > UINT32_MAX) return nil;

    NSMutableData *pointerStorage = [NSMutableData dataWithLength:pool.count * sizeof(const char *)];
    const char **candidates = (const char **)pointerStorage.mutableBytes;
    for (NSUInteger index = 0; index < pool.count; index++) {
        candidates[index] = pool[index].UTF8String;
    }

    RRSelectionResult selection = RRSelectToneAvoidingPrevious(
        true, false, candidates, pool.count, RRLastToneIdentifier.UTF8String, RRBoundedRandom, NULL);
    if (selection.useOriginalTone || selection.toneIdentifier == NULL) return nil;

    RRLastToneIdentifier = [NSString stringWithUTF8String:selection.toneIdentifier];
    RRLastPickTime = CFAbsoluteTimeGetCurrent();
    return RRLastToneIdentifier;
}

/*
 * Returns nil whenever the system result should be used unchanged. A new ring
 * (newRing = YES) always gets a fresh pick different from the previous one.
 */
static NSString *RRRandomRingtoneIdentifier(BOOL newRing) {
    NSDictionary *preferences = RRPreferences();
    if (![preferences[RR_PREFERENCE_ENABLED_KEY] boolValue]) return nil;

    id call = RRRingingIncomingCall();
    if (call != nil && !RRCallIsCellular(call)) return nil;

    id manager = RRToneManager();
    NSInteger slot = RRSIMSlotForCall(call, preferences);
    NSDictionary *accounts = preferences[RR_PREFERENCE_SIM_ACCOUNTS_KEY];
    BOOL perSIM = [preferences[RR_PREFERENCE_PER_SIM_KEY] boolValue] &&
                  [accounts isKindOfClass:NSDictionary.class] &&
                  [NSSet setWithArray:accounts.allValues].count >= 2;

    NSMutableOrderedSet<NSString *> *pool = [NSMutableOrderedSet orderedSet];
    if (perSIM && slot != 0) {
        NSString *key = slot == 1 ? RR_PREFERENCE_SIM1_TONE_IDS_KEY : RR_PREFERENCE_SIM2_TONE_IDS_KEY;
        RRAddValidTones(pool, preferences[key], manager);
    } else if (perSIM) {
        RRAddValidTones(pool, preferences[RR_PREFERENCE_SIM1_TONE_IDS_KEY], manager);
        RRAddValidTones(pool, preferences[RR_PREFERENCE_SIM2_TONE_IDS_KEY], manager);
        if (pool.count == 0) RRAddValidTones(pool, preferences[RR_PREFERENCE_SELECTED_TONE_IDS_KEY], manager);
    } else {
        RRAddValidTones(pool, preferences[RR_PREFERENCE_SELECTED_TONE_IDS_KEY], manager);
    }
    if (pool.count == 0) return nil;

    @synchronized (RRStateLock) {
        CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - RRLastPickTime;
        if (!newRing && RRLastToneIdentifier != nil && elapsed >= 0 && elapsed <= RRSameRingWindow &&
            [pool containsObject:RRLastToneIdentifier]) {
            return RRLastToneIdentifier;
        }
        NSString *identifier = RRPickNewTone(pool.array);
        NSLog(@"RadromRing: %@ picked %@ (slot %ld, per-SIM %d, %lu candidates, call %@)",
              [NSProcessInfo processInfo].processName, identifier, (long)slot, perSIM,
              (unsigned long)pool.count, call != nil ? @"found" : @"unknown");
        return identifier;
    }
}

static NSString *RRGuardedRandomRingtone(BOOL newRing) {
    if (RRResolvingTone) return nil;
    RRResolvingTone = YES;
    NSString *identifier = nil;
    @autoreleasepool {
        identifier = RRRandomRingtoneIdentifier(newRing);
    }
    RRResolvingTone = NO;
    return identifier;
}

#pragma mark - Hooks

static id RRReplacementForDefaultTone(long long alertType, id original) {
    if (alertType != RRAlertTypeIncomingCall) return original;
    if (RRAlertTone != NULL) return (__bridge NSString *)RRAlertTone;
    return RRGuardedRandomRingtone(NO) ?: original;
}

static id RRHookCurrentToneForTypeTopic(id self, SEL selector, long long alertType, id topic) {
    id original = RROriginalCurrentToneForTypeTopic(self, selector, alertType, topic);
    return RRReplacementForDefaultTone(alertType, original);
}

static id RRHookCurrentToneForType(id self, SEL selector, long long alertType) {
    id original = RROriginalCurrentToneForType(self, selector, alertType);
    return RRReplacementForDefaultTone(alertType, original);
}

static id RRHookAlertWithConfiguration(id self, SEL selector, id configuration) {
    BOOL hasType = NO;
    long long alertType = RRIntegerGetter(configuration, @"type", &hasType);
    if (!hasType || alertType != RRAlertTypeIncomingCall || RRAlertTone != NULL) {
        return RROriginalAlertWithConfiguration(self, selector, configuration);
    }

    BOOL explicitTone = RRStringValue(RRCallObjectGetter(configuration, @"toneIdentifier")) != nil;
    BOOL externalTone = RRCallObjectGetter(configuration, @"externalToneFileURL") != nil;
    NSString *tone = explicitTone || externalTone ? nil : RRGuardedRandomRingtone(YES);
    NSLog(@"RadromRing: incoming-call alert in %@ (explicit tone: %d, external: %d, replaced: %d)",
          [NSProcessInfo processInfo].processName, explicitTone, externalTone, tone != nil);
    if (tone == nil) return RROriginalAlertWithConfiguration(self, selector, configuration);

    /* Copy so a configuration reused by the caller still counts as "no explicit tone" next ring. */
    id effective = configuration;
    if ([configuration conformsToProtocol:@protocol(NSCopying)]) {
        @try {
            effective = [configuration copy];
        } @catch (NSException *exception) {
            effective = configuration;
        }
    }
    SEL setter = NSSelectorFromString(@"setToneIdentifier:");
    if ([effective respondsToSelector:setter]) {
        void (*sendMessage)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        sendMessage(effective, setter, tone);
    }

    RRAlertTone = (__bridge void *)tone;
    id alert = RROriginalAlertWithConfiguration(self, selector, effective);
    RRAlertTone = NULL;
    return alert;
}

static void RRHookMethod(Class targetClass, SEL selector, IMP replacement, IMP *original) {
    if (*original != NULL || targetClass == Nil) return;
    if (class_getInstanceMethod(targetClass, selector) == NULL) return;
    MSHookMessageEx(targetClass, selector, replacement, original);
    NSLog(@"RadromRing: hooked %@ %@ in %@", NSStringFromClass(targetClass),
          NSStringFromSelector(selector), [NSProcessInfo processInfo].processName);
}

static BOOL RRInstallHooks(void) {
    dlopen("/System/Library/PrivateFrameworks/ToneLibrary.framework/ToneLibrary", RTLD_LAZY);

    Class managerClass = objc_getClass("TLToneManager");
    RRHookMethod(managerClass,
                 NSSelectorFromString(@"currentToneIdentifierForAlertType:topic:"),
                 (IMP)RRHookCurrentToneForTypeTopic,
                 (IMP *)&RROriginalCurrentToneForTypeTopic);
    RRHookMethod(managerClass,
                 NSSelectorFromString(@"currentToneIdentifierForAlertType:"),
                 (IMP)RRHookCurrentToneForType,
                 (IMP *)&RROriginalCurrentToneForType);

    Class alertClass = objc_getClass("TLAlert");
    RRHookMethod(alertClass != Nil ? object_getClass(alertClass) : Nil,
                 NSSelectorFromString(@"alertWithConfiguration:"),
                 (IMP)RRHookAlertWithConfiguration,
                 (IMP *)&RROriginalAlertWithConfiguration);

    /* Only used to find the ringing call's SIM; optional. */
    RRHookMethod(objc_getClass("TUCall"), @selector(init), (IMP)RRHookCallInit,
                 (IMP *)&RROriginalCallInit);

    return (RROriginalCurrentToneForTypeTopic != NULL || RROriginalCurrentToneForType != NULL) &&
           RROriginalAlertWithConfiguration != NULL && RROriginalCallInit != NULL;
}

static void RRScheduleInstallPoll(void) {
    if (RRInstallPollScheduled || RRInstallPollCount >= RRMaxInstallPolls) return;

    RRInstallPollScheduled = YES;
    RRInstallPollCount++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RRInstallPollScheduled = NO;
        if (!RRInstallHooks()) RRScheduleInstallPoll();
    });
}

__attribute__((constructor))
static void RRInitialize(void) {
    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName;
        RRIsInCallService = [processName isEqualToString:@"InCallService"];
        if (![processName isEqualToString:@"callservicesd"] && !RRIsInCallService) return;

        RRStateLock = [[NSObject alloc] init];
        RRTrackedCalls = [NSHashTable weakObjectsHashTable];
        if (!RRInstallHooks()) RRScheduleInstallPoll();
    }
}
