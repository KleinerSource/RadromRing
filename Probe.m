#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <fcntl.h>
#import <limits.h>
#import <string.h>
#import <sys/stat.h>
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
static NSMutableSet<NSString *> *RRLoggedRuntimeClasses;
static BOOL RRDidLogToneManagerAbsence;
static BOOL RRDidLogToneManagerCapabilities;

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

static id RRRawObjectValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }

    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

static id RRObjectValue(id object, NSString *selectorName) {
    id value = RRRawObjectValue(object, selectorName);
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

static BOOL RRHasObjectValue(id object, NSString *selectorName) {
    id value = RRRawObjectValue(object, selectorName);
    return value != nil && value != NSNull.null &&
           !([value isKindOfClass:NSString.class] && [(NSString *)value length] == 0);
}

static BOOL RRSelectorLooksRelevant(NSString *selectorName) {
    NSArray<NSString *> *terms = @[@"ring", @"tone", @"sound", @"alert", @"contact"];
    for (NSString *term in terms) {
        if ([selectorName rangeOfString:term options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void RRLogRelevantSelectors(Class targetClass) {
    if (targetClass == Nil) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        RRLoggedRuntimeClasses = [NSMutableSet set];
    });

    NSString *className = NSStringFromClass(targetClass);
    @synchronized (RRLoggedRuntimeClasses) {
        if ([RRLoggedRuntimeClasses containsObject:className]) return;
        [RRLoggedRuntimeClasses addObject:className];
    }

    NSMutableOrderedSet<NSString *> *selectors = [NSMutableOrderedSet orderedSet];
    for (Class current = targetClass; current != Nil && current != NSObject.class;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            NSString *name = NSStringFromSelector(method_getName(methods[index]));
            if (RRSelectorLooksRelevant(name)) [selectors addObject:name];
        }
        free(methods);
    }

    RRLog(@"event=relevant-selectors class=%@ selectors=%@",
          className, [[selectors array] componentsJoinedByString:@","]);
}

static void RRLogToneManagerCapabilities(void) {
    Class managerClass = objc_getClass("TLToneManager");
    if (managerClass == Nil) {
        if (!RRDidLogToneManagerAbsence) {
            RRDidLogToneManagerAbsence = YES;
            RRLog(@"event=tone-manager-present value=NO");
        }
        return;
    }
    if (RRDidLogToneManagerCapabilities) return;
    RRDidLogToneManagerCapabilities = YES;

    RRLog(@"event=tone-manager-present value=YES");
    const char *instanceSelectors[] = {
        "nameForToneIdentifier:",
        "filePathForToneIdentifier:",
        "defaultRingtoneIdentifier",
        "toneWithIdentifierIsValid:",
        "currentToneIdentifierForAlertType:",
    };
    for (size_t index = 0; index < sizeof(instanceSelectors) / sizeof(instanceSelectors[0]); index++) {
        SEL selector = sel_registerName(instanceSelectors[index]);
        Method method = class_getInstanceMethod(managerClass, selector);
        if (method != NULL) {
            RRLog(@"event=tone-manager-method selector=%s encoding=%s",
                  instanceSelectors[index], method_getTypeEncoding(method));
        }
    }

    Method sharedManager = class_getClassMethod(managerClass, sel_registerName("sharedToneManager"));
    if (sharedManager != NULL) {
        RRLog(@"event=tone-manager-method selector=sharedToneManager encoding=%s",
              method_getTypeEncoding(sharedManager));
    }
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

    RRLogRelevantSelectors(object_getClass(call));
    id model = RRRawObjectValue(call, @"model");
    if (model != nil) RRLogRelevantSelectors(object_getClass(model));

    return [NSString stringWithFormat:@"incoming=%@ hasContact=%@ status=%lld",
                                      RRBooleanValue(call, @"isIncoming"),
                                      RRHasObjectValue(call, @"contactIdentifier") ? @"YES" : @"NO",
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

    RRLogToneManagerCapabilities();

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
        RRLogToneManagerCapabilities();
        RRScheduleInstallPoll();
    }
}
