#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <fcntl.h>
#import <limits.h>
#import <string.h>
#import <unistd.h>
#import <stdarg.h>
#import <dispatch/dispatch.h>

static NSString *const RRProbeLogPath = @"/var/mobile/Library/Logs/RadromRingProbe.log";

typedef BOOL (*RRPlaySoundTypeIMP)(id, SEL, long long, id);
typedef BOOL (*RRPlaySoundTypeCompletionIMP)(id, SEL, long long, id, id);
typedef BOOL (*RRPlayDescriptorIMP)(id, SEL, id);
typedef BOOL (*RRPlayDescriptorCompletionIMP)(id, SEL, id, id);

static RRPlaySoundTypeIMP RROriginalPlaySoundType;
static RRPlaySoundTypeCompletionIMP RROriginalPlaySoundTypeCompletion;
static RRPlayDescriptorIMP RROriginalPlayDescriptor;
static RRPlayDescriptorCompletionIMP RROriginalPlayDescriptorCompletion;
static BOOL RRDidHookPlaySoundType;
static BOOL RRDidHookPlaySoundTypeCompletion;
static BOOL RRDidHookPlayDescriptor;
static BOOL RRDidHookPlayDescriptorCompletion;
static BOOL RRInstallPollScheduled;
static NSUInteger RRInstallAttempts;

static void RRLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void RRLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSString *line = [NSString stringWithFormat:@"%@ pid=%d %@\n",
                                                NSProcessInfo.processInfo.processName,
                                                getpid(),
                                                message];
    @synchronized (RRProbeLogPath) {
        int descriptor = open(RRProbeLogPath.fileSystemRepresentation,
                              O_WRONLY | O_CREAT | O_APPEND,
                              0644);
        if (descriptor >= 0) {
            fchmod(descriptor, 0644);
            (void)write(descriptor, line.UTF8String, strlen(line.UTF8String));
            close(descriptor);
        }
    }
    NSLog(@"[RadromRingProbe] %@", message);
}

static id RRObjectValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return @"<unavailable>";
    }

    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id value = sendMessage(object, selector);
    return value ?: @"<nil>";
}

static NSString *RRBooleanValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return @"<unavailable>";
    }

    BOOL (*sendMessage)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector) ? @"YES" : @"NO";
}

static long long RRLongLongValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return LLONG_MIN;
    }

    long long (*sendMessage)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static unsigned long long RRUnsignedLongLongValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return ULLONG_MAX;
    }

    unsigned long long (*sendMessage)(id, SEL) =
        (unsigned long long (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static double RRDoubleValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return -1.0;
    }

    double (*sendMessage)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static NSString *RRCallSummary(id call) {
    if (call == nil || call == NSNull.null) {
        return @"<nil>";
    }

    return [NSString stringWithFormat:@"incoming=%@ uuid=%@ contactID=%@ status=%lld",
                                      RRBooleanValue(call, @"isIncoming"),
                                      RRObjectValue(call, @"callUUID"),
                                      RRObjectValue(call, @"contactIdentifier"),
                                      RRLongLongValue(call, @"callStatus")];
}

static NSString *RRDescriptorSummary(id descriptor) {
    if (descriptor == nil || descriptor == NSNull.null) {
        return @"<nil>";
    }

    return [NSString stringWithFormat:@"soundType=%lld sound=%@ iterations=%llu pause=%.3f",
                                      RRLongLongValue(descriptor, @"soundType"),
                                      RRObjectValue(descriptor, @"sound"),
                                      RRUnsignedLongLongValue(descriptor, @"iterations"),
                                      RRDoubleValue(descriptor, @"pauseDuration")];
}

static BOOL RRHookPlaySoundType(id self, SEL selector, long long soundType, id call) {
    RRLog(@"event=call-sound selector=%@ soundType=%lld %@",
          NSStringFromSelector(selector), soundType, RRCallSummary(call));
    return RROriginalPlaySoundType(self, selector, soundType, call);
}

static BOOL RRHookPlaySoundTypeCompletion(id self,
                                          SEL selector,
                                          long long soundType,
                                          id call,
                                          id completion) {
    RRLog(@"event=call-sound selector=%@ soundType=%lld %@",
          NSStringFromSelector(selector), soundType, RRCallSummary(call));
    return RROriginalPlaySoundTypeCompletion(self, selector, soundType, call, completion);
}

static BOOL RRHookPlayDescriptor(id self, SEL selector, id descriptor) {
    RRLog(@"event=descriptor selector=%@ %@",
          NSStringFromSelector(selector), RRDescriptorSummary(descriptor));
    return RROriginalPlayDescriptor(self, selector, descriptor);
}

static BOOL RRHookPlayDescriptorCompletion(id self,
                                           SEL selector,
                                           id descriptor,
                                           id completion) {
    RRLog(@"event=descriptor selector=%@ %@",
          NSStringFromSelector(selector), RRDescriptorSummary(descriptor));
    return RROriginalPlayDescriptorCompletion(self, selector, descriptor, completion);
}

static BOOL RRInstallInstanceHook(Class targetClass,
                                  SEL selector,
                                  IMP replacement,
                                  IMP *original,
                                  NSString *label) {
    Method method = class_getInstanceMethod(targetClass, selector);
    if (method == NULL) {
        return NO;
    }

    MSHookMessageEx(targetClass, selector, replacement, original);
    RRLog(@"event=hook-installed class=%@ selector=%@ encoding=%s",
          label, NSStringFromSelector(selector), method_getTypeEncoding(method));
    return YES;
}

static void RRInstallHooks(void) {
    Class playerClass = objc_getClass("TUCallSoundPlayer");
    if (playerClass != Nil) {
        if (!RRDidHookPlaySoundType) {
            RRDidHookPlaySoundType = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlaySoundType:forCall:"),
                (IMP)RRHookPlaySoundType,
                (IMP *)&RROriginalPlaySoundType,
                @"TUCallSoundPlayer");
        }
        if (!RRDidHookPlaySoundTypeCompletion) {
            RRDidHookPlaySoundTypeCompletion = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlaySoundType:forCall:completion:"),
                (IMP)RRHookPlaySoundTypeCompletion,
                (IMP *)&RROriginalPlaySoundTypeCompletion,
                @"TUCallSoundPlayer");
        }
        if (!RRDidHookPlayDescriptor) {
            RRDidHookPlayDescriptor = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlayDescriptor:"),
                (IMP)RRHookPlayDescriptor,
                (IMP *)&RROriginalPlayDescriptor,
                @"TUCallSoundPlayer");
        }
        if (!RRDidHookPlayDescriptorCompletion) {
            RRDidHookPlayDescriptorCompletion = RRInstallInstanceHook(
                playerClass,
                NSSelectorFromString(@"attemptToPlayDescriptor:completion:"),
                (IMP)RRHookPlayDescriptorCompletion,
                (IMP *)&RROriginalPlayDescriptorCompletion,
                @"TUCallSoundPlayer");
        }
    }

    if (objc_getClass("TUCallSoundPlayerDescriptor") != Nil) {
        Class descriptorClass = objc_getClass("TUCallSoundPlayerDescriptor");
        Method initMethod = class_getInstanceMethod(
            descriptorClass, NSSelectorFromString(@"initWithSoundType:call:"));
        RRLog(@"event=class-present class=TUCallSoundPlayerDescriptor initEncoding=%s",
              initMethod ? method_getTypeEncoding(initMethod) : "<missing-init>");
    }

    if (playerClass == Nil && RRInstallAttempts == 0) {
        RRLog(@"event=class-missing class=TUCallSoundPlayer");
    }
}

static void RRScheduleInstallPoll(void) {
    if (RRInstallPollScheduled || RRInstallAttempts >= 40) {
        return;
    }

    RRInstallPollScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RRInstallPollScheduled = NO;
        RRInstallAttempts += 1;
        RRInstallHooks();

        BOOL allExpectedHooksInstalled = RRDidHookPlaySoundType ||
                                         RRDidHookPlaySoundTypeCompletion ||
                                         RRDidHookPlayDescriptor ||
                                         RRDidHookPlayDescriptorCompletion;
        if (!allExpectedHooksInstalled) {
            RRScheduleInstallPoll();
        }
    });
}

__attribute__((constructor))
static void RRInitialize(void) {
    @autoreleasepool {
        RRLog(@"event=process-loaded");
        RRInstallHooks();
        RRScheduleInstallPoll();
    }
}
