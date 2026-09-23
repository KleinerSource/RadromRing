#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <limits.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

#import <substrate.h>

#import "core/RRPreferences.h"
#import "core/RRSelection.h"

typedef BOOL (*RRPlaySoundTypeIMP)(id, SEL, long long, id);
typedef BOOL (*RRPlaySoundTypeCompletionIMP)(id, SEL, long long, id, id);
typedef BOOL (*RRPlayDescriptorIMP)(id, SEL, id);
typedef BOOL (*RRPlayDescriptorCompletionIMP)(id, SEL, id, id);
typedef id (*RRInitDescriptorIMP)(id, SEL, long long, id);
typedef CFTypeRef (*RRAddressBookSoundLookupIMP)(const void *, int32_t);

static RRPlaySoundTypeIMP RROriginalPlaySoundType;
static RRPlaySoundTypeCompletionIMP RROriginalPlaySoundTypeCompletion;
static RRPlayDescriptorIMP RROriginalPlayDescriptor;
static RRPlayDescriptorCompletionIMP RROriginalPlayDescriptorCompletion;
static RRInitDescriptorIMP RROriginalInitDescriptor;
static RRAddressBookSoundLookupIMP RROriginalIndividualContactSoundLookup;
static RRAddressBookSoundLookupIMP RROriginalLinkedContactSoundLookup;
static RRAddressBookSoundLookupIMP RROriginalContactSoundLookup;

static BOOL RRDidHookPlaySoundType;
static BOOL RRDidHookPlaySoundTypeCompletion;
static BOOL RRDidHookPlayDescriptor;
static BOOL RRDidHookPlayDescriptorCompletion;
static BOOL RRDidHookInitDescriptor;
static BOOL RRDidHookAddressBook;
static BOOL RRInstallPollScheduled;
static NSUInteger RRInstallAttempts;
static __thread void *RRCurrentCall;

static char RRDescriptorCallKey;
static char RRContactToneCheckedKey;
static char RRContactToneFoundKey;
static char RRCallToneStateKey;

static const long long RRIncomingRingtoneSoundType = 1;
static NSCache<NSString *, id> *RRCallToneCache;

static NSCache<NSString *, id> *RRToneCache(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        RRCallToneCache = [[NSCache alloc] init];
        RRCallToneCache.countLimit = 32;
    });
    return RRCallToneCache;
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

static unsigned int RRUnsignedIntGetter(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return 0;
    unsigned int (*sendMessage)(id, SEL) = (unsigned int (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static unsigned long long RRUnsignedLongLongGetter(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return ULLONG_MAX;
    unsigned long long (*sendMessage)(id, SEL) =
        (unsigned long long (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static long long RRIntegerGetter(id object, NSString *selectorName, BOOL *available) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        if (available != NULL) *available = NO;
        return LLONG_MIN;
    }
    if (available != NULL) *available = YES;
    long long (*sendMessage)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static NSString *RRStringValue(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

static NSString *RRCallStableIdentifier(id call) {
    id identifier = RRCallObjectGetter(call, @"callUUID");
    if (identifier == nil) identifier = RRCallObjectGetter(call, @"uniqueProxyIdentifierUUID");
    NSString *string = RRStringValue(identifier);
    if (string != nil) return string;

    SEL uuidString = NSSelectorFromString(@"UUIDString");
    if ([identifier respondsToSelector:uuidString]) {
        id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return RRStringValue(sendMessage(identifier, uuidString));
    }
    return nil;
}

static BOOL RRCallHasContactInfo(id call) {
    if (RRStringValue(RRCallObjectGetter(call, @"contactIdentifier")) != nil) return YES;

    id identifiers = RRCallObjectGetter(call, @"contactIdentifiers");
    if ([identifiers isKindOfClass:NSArray.class] && [(NSArray *)identifiers count] > 0) return YES;

    id displayContext = RRCallObjectGetter(call, @"displayContext");
    id legacyIdentifier = RRCallObjectGetter(displayContext, @"legacyAddressBookIdentifier");
    return legacyIdentifier != nil && legacyIdentifier != NSNull.null;
}

static BOOL RRCallIsIncomingCellular(id call) {
    BOOL hasIncomingProperty = NO;
    if (!RRCallBooleanGetter(call, @"isIncoming", &hasIncomingProperty) || !hasIncomingProperty) return NO;

    BOOL hasVoIPProperty = NO;
    if (RRCallBooleanGetter(call, @"isVoIPCall", &hasVoIPProperty) && hasVoIPProperty) return NO;

    id provider = RRCallObjectGetter(call, @"provider");
    BOOL hasTelephonyProperty = NO;
    return RRCallBooleanGetter(provider, @"isTelephonyProvider", &hasTelephonyProperty) &&
           hasTelephonyProperty;
}

static BOOL RRCallHasContactTone(id call) {
    return [objc_getAssociatedObject(call, &RRContactToneFoundKey) boolValue];
}

static BOOL RRCallContactToneWasChecked(id call) {
    return [objc_getAssociatedObject(call, &RRContactToneCheckedKey) boolValue];
}

static void RRRecordAddressBookToneLookup(CFTypeRef toneIdentifier) {
    id call = (__bridge id)RRCurrentCall;
    if (call == nil) return;

    objc_setAssociatedObject(call, &RRContactToneCheckedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (toneIdentifier != NULL) {
        objc_setAssociatedObject(call, &RRContactToneFoundKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

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
    if (manager == nil || ![manager respondsToSelector:selector]) return NO;
    BOOL (*sendMessage)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return sendMessage(manager, selector, identifier);
}

static NSArray<NSString *> *RRValidSelectedToneIdentifiers(id manager) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)RR_PREFERENCE_SELECTED_TONE_IDS_KEY,
        CFSTR(RR_PREFERENCES_DOMAIN));
    id configured = CFBridgingRelease(value);
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

static unsigned int RRSoundIDForToneIdentifier(id manager, NSString *identifier) {
    SEL soundForTone = NSSelectorFromString(@"_soundForToneIdentifier:");
    if (manager == nil || ![manager respondsToSelector:soundForTone]) return 0;
    id (*sendMessage)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    id sound = sendMessage(manager, soundForTone, identifier);
    return RRUnsignedIntGetter(sound, @"soundID");
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

static unsigned int RRRandomSoundIDForCall(id call, id manager) {
    if (call == nil || manager == nil) return 0;

    CFPropertyListRef enabledValue = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)RR_PREFERENCE_ENABLED_KEY,
        CFSTR(RR_PREFERENCES_DOMAIN));
    id enabledObject = CFBridgingRelease(enabledValue);
    if (![enabledObject boolValue]) return 0;

    NSArray<NSString *> *identifiers = RRValidSelectedToneIdentifiers(manager);
    if (identifiers.count == 0) return 0;

    id state = objc_getAssociatedObject(call, &RRCallToneStateKey);
    NSString *stableIdentifier = RRCallStableIdentifier(call);
    if (state == nil && stableIdentifier != nil) {
        state = [RRToneCache() objectForKey:stableIdentifier];
    }

    if (state == NSNull.null) return 0;
    if ([state isKindOfClass:NSDictionary.class]) {
        NSString *identifier = state[@"identifier"];
        if (!RRToneIdentifierIsValid(manager, identifier)) return 0;
        return [state[@"soundID"] unsignedIntValue];
    }

    NSString *identifier = RRChooseToneIdentifier(identifiers);
    if (identifier == nil) {
        objc_setAssociatedObject(call, &RRCallToneStateKey, NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (stableIdentifier != nil) [RRToneCache() setObject:NSNull.null forKey:stableIdentifier];
        return 0;
    }

    unsigned int soundID = RRSoundIDForToneIdentifier(manager, identifier);
    if (soundID == 0) {
        objc_setAssociatedObject(call, &RRCallToneStateKey, NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (stableIdentifier != nil) [RRToneCache() setObject:NSNull.null forKey:stableIdentifier];
        return 0;
    }

    NSDictionary *selection = @{ @"identifier": identifier, @"soundID": @(soundID) };
    objc_setAssociatedObject(call, &RRCallToneStateKey, selection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stableIdentifier != nil) {
        [RRToneCache() setObject:selection forKey:stableIdentifier];
    }
    return soundID;
}

static void RRMaybeRandomizeDescriptor(id descriptor) {
    id call = objc_getAssociatedObject(descriptor, &RRDescriptorCallKey);
    if (call == nil) call = (__bridge id)RRCurrentCall;
    if (!RRCallIsIncomingCellular(call)) return;
    if (RRCallHasContactTone(call)) return;
    BOOL hasKnownCallerProperty = NO;
    BOOL knownCaller = RRCallBooleanGetter(call, @"isKnownCaller", &hasKnownCallerProperty);
    if ((RRCallHasContactInfo(call) || (hasKnownCallerProperty && knownCaller)) &&
        !RRCallContactToneWasChecked(call)) return;

    BOOL hasSoundType = NO;
    long long soundType = RRIntegerGetter(descriptor, @"soundType", &hasSoundType);
    if (!hasSoundType || soundType != RRIncomingRingtoneSoundType) return;
    if (RRUnsignedLongLongGetter(descriptor, @"iterations") != ULLONG_MAX) return;

    id manager = RRToneManager();
    unsigned int soundID = RRRandomSoundIDForCall(call, manager);
    if (soundID == 0) return;

    SEL setter = NSSelectorFromString(@"setSound:");
    if (![descriptor respondsToSelector:setter]) return;
    void (*sendMessage)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    sendMessage(descriptor, setter, @(soundID));
}

static id RRHookInitDescriptor(id self, SEL selector, long long soundType, id call) {
    void *previousCall = RRCurrentCall;
    RRCurrentCall = (__bridge void *)call;
    id descriptor = RROriginalInitDescriptor(self, selector, soundType, call);
    RRCurrentCall = previousCall;

    if (descriptor != nil && call != nil) {
        objc_setAssociatedObject(descriptor, &RRDescriptorCallKey, call, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return descriptor;
}

static BOOL RRHookPlaySoundType(id self, SEL selector, long long soundType, id call) {
    void *previousCall = RRCurrentCall;
    RRCurrentCall = (__bridge void *)call;
    BOOL result = RROriginalPlaySoundType(self, selector, soundType, call);
    RRCurrentCall = previousCall;
    return result;
}

static BOOL RRHookPlaySoundTypeCompletion(id self,
                                          SEL selector,
                                          long long soundType,
                                          id call,
                                          id completion) {
    void *previousCall = RRCurrentCall;
    RRCurrentCall = (__bridge void *)call;
    BOOL result = RROriginalPlaySoundTypeCompletion(self, selector, soundType, call, completion);
    RRCurrentCall = previousCall;
    return result;
}

static BOOL RRHookPlayDescriptor(id self, SEL selector, id descriptor) {
    @autoreleasepool {
        RRMaybeRandomizeDescriptor(descriptor);
    }
    return RROriginalPlayDescriptor(self, selector, descriptor);
}

static BOOL RRHookPlayDescriptorCompletion(id self,
                                           SEL selector,
                                           id descriptor,
                                           id completion) {
    @autoreleasepool {
        RRMaybeRandomizeDescriptor(descriptor);
    }
    return RROriginalPlayDescriptorCompletion(self, selector, descriptor, completion);
}

static CFTypeRef RRHookIndividualContactSoundLookup(const void *record, int32_t identifier) {
    CFTypeRef result = RROriginalIndividualContactSoundLookup(record, identifier);
    RRRecordAddressBookToneLookup(result);
    return result;
}

static CFTypeRef RRHookLinkedContactSoundLookup(const void *record, int32_t identifier) {
    CFTypeRef result = RROriginalLinkedContactSoundLookup(record, identifier);
    RRRecordAddressBookToneLookup(result);
    return result;
}

static CFTypeRef RRHookContactSoundLookup(const void *record, int32_t identifier) {
    CFTypeRef result = RROriginalContactSoundLookup(record, identifier);
    RRRecordAddressBookToneLookup(result);
    return result;
}

static BOOL RRInstallInstanceHook(Class targetClass,
                                  SEL selector,
                                  IMP replacement,
                                  IMP *original) {
    if (targetClass == Nil || class_getInstanceMethod(targetClass, selector) == NULL) return NO;
    MSHookMessageEx(targetClass, selector, replacement, original);
    return YES;
}

static void RRInstallAddressBookHooks(void) {
    if (RRDidHookAddressBook) return;
    void *handle = dlopen("/System/Library/PrivateFrameworks/AddressBookLegacy.framework/AddressBookLegacy",
                          RTLD_LAZY);
    if (handle == NULL) return;

    void *individual = dlsym(handle,
        "ABPersonCopySoundIdentifierForMultiValueIdentifierForIndividualContact");
    if (individual != NULL) {
        MSHookFunction(individual, (void *)RRHookIndividualContactSoundLookup,
                       (void **)&RROriginalIndividualContactSoundLookup);
    }

    void *linked = dlsym(handle,
        "ABPersonCopySoundIdentifierForMultiValueIdentifierIncludingLinkedContacts");
    if (linked != NULL) {
        MSHookFunction(linked, (void *)RRHookLinkedContactSoundLookup,
                       (void **)&RROriginalLinkedContactSoundLookup);
    }

    void *generic = dlsym(handle, "ABPersonCopySoundIdentifierForMultiValueIdentifier");
    if (generic != NULL) {
        MSHookFunction(generic, (void *)RRHookContactSoundLookup,
                       (void **)&RROriginalContactSoundLookup);
    }

    RRDidHookAddressBook = RROriginalIndividualContactSoundLookup != NULL ||
                           RROriginalLinkedContactSoundLookup != NULL ||
                           RROriginalContactSoundLookup != NULL;
}

static void RRInstallHooks(void) {
    Class playerClass = objc_getClass("TUCallSoundPlayer");
    if (playerClass != Nil) {
        if (RROriginalPlaySoundType == NULL) {
            RRDidHookPlaySoundType = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlaySoundType:forCall:"),
                (IMP)RRHookPlaySoundType,
                (IMP *)&RROriginalPlaySoundType);
        }
        if (RROriginalPlaySoundTypeCompletion == NULL) {
            RRDidHookPlaySoundTypeCompletion = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlaySoundType:forCall:completion:"),
                (IMP)RRHookPlaySoundTypeCompletion,
                (IMP *)&RROriginalPlaySoundTypeCompletion);
        }
        if (RROriginalPlayDescriptor == NULL) {
            RRDidHookPlayDescriptor = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlayDescriptor:"),
                (IMP)RRHookPlayDescriptor,
                (IMP *)&RROriginalPlayDescriptor);
        }
        if (RROriginalPlayDescriptorCompletion == NULL) {
            RRDidHookPlayDescriptorCompletion = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlayDescriptor:completion:"),
                (IMP)RRHookPlayDescriptorCompletion,
                (IMP *)&RROriginalPlayDescriptorCompletion);
        }
    }

    Class descriptorClass = objc_getClass("TUCallSoundPlayerDescriptor");
    if (descriptorClass != Nil && RROriginalInitDescriptor == NULL) {
        RRDidHookInitDescriptor = RRInstallInstanceHook(
            descriptorClass,
            NSSelectorFromString(@"initWithSoundType:call:"),
            (IMP)RRHookInitDescriptor,
            (IMP *)&RROriginalInitDescriptor);
    }

    RRInstallAddressBookHooks();
}

static void RRScheduleInstallPoll(void) {
    if (RRInstallPollScheduled || RRInstallAttempts >= 40) return;

    RRInstallPollScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RRInstallPollScheduled = NO;
        RRInstallAttempts += 1;
        RRInstallHooks();

        BOOL hooksInstalled = RRDidHookPlaySoundType || RRDidHookPlaySoundTypeCompletion ||
                              RRDidHookPlayDescriptor || RRDidHookPlayDescriptorCompletion ||
                              RRDidHookInitDescriptor;
        if (!hooksInstalled || !RRDidHookAddressBook) RRScheduleInstallPoll();
    });
}

__attribute__((constructor))
static void RRInitialize(void) {
    @autoreleasepool {
        RRInstallHooks();
        RRScheduleInstallPoll();
    }
}
