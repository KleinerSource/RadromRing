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
 * The incoming-call ringtone is resolved through ToneLibrary: a TLAlert of type
 * TLAlertTypeIncomingCall without an explicit toneIdentifier asks TLToneManager for
 * the current default. Contact-specific ringtones arrive as explicit identifiers and
 * never reach the default lookup, so replacing only that lookup keeps them intact,
 * including when a contact's tone happens to equal the default.
 */

typedef id (*RRCurrentToneForTypeTopicIMP)(id, SEL, long long, id);
typedef id (*RRCurrentToneForTypeIMP)(id, SEL, long long);
typedef id (*RRAlertWithConfigurationIMP)(id, SEL, id);

static RRCurrentToneForTypeTopicIMP RROriginalCurrentToneForTypeTopic;
static RRCurrentToneForTypeIMP RROriginalCurrentToneForType;
static RRAlertWithConfigurationIMP RROriginalAlertWithConfiguration;

static BOOL RRInstallPollScheduled;
static NSUInteger RRInstallPollCount;
static __thread BOOL RRResolvingTone;

static const long long RRAlertTypeIncomingCall = 1;
/* Lookups closer together than this belong to the same ringing call. */
static const CFAbsoluteTime RRRingSessionWindow = 10.0;
static const NSUInteger RRMaxInstallPolls = 240;

static NSString *RRSessionToneIdentifier;
static CFAbsoluteTime RRSessionLastUse;

static NSString *RRStringValue(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

static id RRCallObjectGetter(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
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

static id RRPreferenceValue(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                     CFSTR(RR_PREFERENCES_DOMAIN),
                                                     kCFPreferencesCurrentUser,
                                                     kCFPreferencesAnyHost);
    if (value != NULL) return CFBridgingRelease(value);

    /* Sandboxed call processes may be denied the cfprefsd domain but not the file. */
    NSString *path = @"/var/mobile/Library/Preferences/" RR_PREFERENCES_DOMAIN ".plist";
    return [NSDictionary dictionaryWithContentsOfFile:path][key];
}

static BOOL RRToneIdentifierIsValid(id manager, NSString *identifier) {
    SEL selector = NSSelectorFromString(@"toneWithIdentifierIsValid:");
    if (manager == nil || identifier == nil || ![manager respondsToSelector:selector]) return NO;
    BOOL (*sendMessage)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return sendMessage(manager, selector, identifier);
}

static NSArray<NSString *> *RRValidSelectedToneIdentifiers(id manager) {
    id configured = RRPreferenceValue(RR_PREFERENCE_SELECTED_TONE_IDS_KEY);
    if (![configured isKindOfClass:NSArray.class]) return @[];

    NSMutableOrderedSet<NSString *> *valid = [NSMutableOrderedSet orderedSet];
    for (id item in (NSArray *)configured) {
        NSString *identifier = RRStringValue(item);
        if (identifier != nil && RRToneIdentifierIsValid(manager, identifier)) {
            [valid addObject:identifier];
        }
    }
    return valid.array;
}

static uint32_t RRBoundedRandom(uint32_t upperBound, void *context) {
    (void)context;
    return arc4random_uniform(upperBound);
}

static NSString *RRChooseToneIdentifier(NSArray<NSString *> *identifiers) {
    if (identifiers.count == 0 || identifiers.count > UINT32_MAX) return nil;

    NSMutableData *pointerStorage = [NSMutableData dataWithLength:identifiers.count * sizeof(const char *)];
    const char **candidates = (const char **)pointerStorage.mutableBytes;
    for (NSUInteger index = 0; index < identifiers.count; index++) {
        candidates[index] = identifiers[index].UTF8String;
    }

    RRSelectionResult selection = RRSelectTone(true, false, candidates, identifiers.count,
                                                RRBoundedRandom, NULL);
    if (selection.useOriginalTone || selection.toneIdentifier == NULL) return nil;
    return [NSString stringWithUTF8String:selection.toneIdentifier];
}

/* Returns nil whenever the system result should be used unchanged. */
static NSString *RRRandomRingtoneIdentifier(id manager) {
    if (![RRPreferenceValue(RR_PREFERENCE_ENABLED_KEY) boolValue]) return nil;

    NSArray<NSString *> *identifiers = RRValidSelectedToneIdentifiers(manager);
    if (identifiers.count == 0) return nil;

    static NSObject *sessionLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sessionLock = [[NSObject alloc] init];
    });

    @synchronized (sessionLock) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL sameRing = RRSessionToneIdentifier != nil &&
                        now - RRSessionLastUse >= 0 &&
                        now - RRSessionLastUse <= RRRingSessionWindow &&
                        [identifiers containsObject:RRSessionToneIdentifier];
        if (!sameRing) {
            NSString *identifier = RRChooseToneIdentifier(identifiers);
            if (identifier == nil) return nil;
            RRSessionToneIdentifier = identifier;
            NSLog(@"RadromRing: selected ringtone %@ from %lu candidates",
                  identifier, (unsigned long)identifiers.count);
        }
        RRSessionLastUse = now;
        return RRSessionToneIdentifier;
    }
}

static id RRReplacementForDefaultTone(id manager, long long alertType, id original) {
    if (alertType != RRAlertTypeIncomingCall || RRResolvingTone) return original;

    RRResolvingTone = YES;
    NSString *replacement = nil;
    @autoreleasepool {
        replacement = RRRandomRingtoneIdentifier(manager);
    }
    RRResolvingTone = NO;
    return replacement ?: original;
}

static id RRHookCurrentToneForTypeTopic(id self, SEL selector, long long alertType, id topic) {
    id original = RROriginalCurrentToneForTypeTopic(self, selector, alertType, topic);
    return RRReplacementForDefaultTone(self, alertType, original);
}

static id RRHookCurrentToneForType(id self, SEL selector, long long alertType) {
    id original = RROriginalCurrentToneForType(self, selector, alertType);
    return RRReplacementForDefaultTone(self, alertType, original);
}

/* Diagnostic only: records whether incoming-call alerts carry an explicit tone. */
static id RRHookAlertWithConfiguration(id self, SEL selector, id configuration) {
    BOOL hasType = NO;
    long long alertType = RRIntegerGetter(configuration, @"type", &hasType);
    if (hasType && alertType == RRAlertTypeIncomingCall) {
        NSLog(@"RadromRing: incoming-call alert in %@ (explicit tone: %d, topic: %d)",
              [NSProcessInfo processInfo].processName,
              RRStringValue(RRCallObjectGetter(configuration, @"toneIdentifier")) != nil,
              RRCallObjectGetter(configuration, @"topic") != nil);
    }
    return RROriginalAlertWithConfiguration(self, selector, configuration);
}

static void RRHookMethod(Class targetClass, SEL selector, IMP replacement, IMP *original) {
    if (*original != NULL || targetClass == Nil) return;
    if (class_getInstanceMethod(targetClass, selector) == NULL) return;
    MSHookMessageEx(targetClass, selector, replacement, original);
    NSLog(@"RadromRing: hooked %@ in %@", NSStringFromSelector(selector),
          [NSProcessInfo processInfo].processName);
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

    return RROriginalCurrentToneForTypeTopic != NULL || RROriginalCurrentToneForType != NULL;
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
        if (![processName isEqualToString:@"callservicesd"] &&
            ![processName isEqualToString:@"InCallService"]) return;

        if (!RRInstallHooks()) RRScheduleInstallPoll();
    }
}
