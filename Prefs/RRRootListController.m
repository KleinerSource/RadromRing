#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

#import "../core/RRPreferences.h"

#ifndef RR_VERSION
#define RR_VERSION "dev"
#endif
#ifndef RR_AUTHOR
#define RR_AUTHOR "KleinerSource"
#endif

static NSString *const RRToneIdentifierProperty = @"rrToneIdentifier";
static NSString *const RRToneListKeyProperty = @"rrToneListKey";

static CFStringRef RRPreferencesDomain(void) {
    return CFSTR(RR_PREFERENCES_DOMAIN);
}

static id RRReadPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        RRPreferencesDomain());
    return CFBridgingRelease(value);
}

static void RRWritePreference(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             RRPreferencesDomain());
    CFPreferencesAppSynchronize(RRPreferencesDomain());
}

static NSArray<NSString *> *RRReadToneList(NSString *key) {
    id value = RRReadPreference(key);
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (id identifier in (NSArray *)value) {
        if ([identifier isKindOfClass:NSString.class]) [identifiers addObject:identifier];
    }
    return identifiers;
}

static void RRWriteToneList(NSString *key, NSSet<NSString *> *identifiers) {
    RRWritePreference(key, [[identifiers allObjects] sortedArrayUsingSelector:@selector(compare:)]);
}

static id RRCallObjectGetter(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

#pragma mark - Tone catalog

static NSString *RRIdentifierFromObject(id object) {
    if ([object isKindOfClass:NSString.class] && [object length] > 0) return object;
    if ([object isKindOfClass:NSDictionary.class]) {
        id value = object[@"toneIdentifier"] ?: object[@"identifier"] ?: object[@"id"];
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    if ([object respondsToSelector:NSSelectorFromString(@"toneIdentifier")]) {
        id value = RRCallObjectGetter(object, @"toneIdentifier");
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    if ([object respondsToSelector:NSSelectorFromString(@"identifier")]) {
        id value = RRCallObjectGetter(object, @"identifier");
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    return nil;
}

static NSArray *RRArrayFromCatalogValue(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSSet.class]) return [(NSSet *)value allObjects];
    if ([value isKindOfClass:NSDictionary.class]) return [(NSDictionary *)value allKeys];
    return @[];
}

static NSArray<NSString *> *RRToneCatalogSelectors(Class managerClass) {
    NSMutableOrderedSet<NSString *> *ringtoneSelectors = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *toneSelectors = [NSMutableOrderedSet orderedSet];
    for (Class current = managerClass; current != Nil && current != NSObject.class;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            Method method = methods[index];
            if (method_getNumberOfArguments(method) != 2) continue;

            char *returnType = method_copyReturnType(method);
            BOOL returnsObject = returnType != NULL && returnType[0] == '@';
            free(returnType);
            if (!returnsObject) continue;

            NSString *name = NSStringFromSelector(method_getName(method));
            NSString *lowercaseName = name.lowercaseString;
            BOOL mentionsTone = [lowercaseName containsString:@"tone"] ||
                                [lowercaseName containsString:@"ring"];
            BOOL looksLikeList = [lowercaseName containsString:@"identifier"] ||
                                 [lowercaseName containsString:@"ringtones"] ||
                                 [lowercaseName containsString:@"tonelist"] ||
                                 [lowercaseName hasSuffix:@"tones"];
            if (!mentionsTone || !looksLikeList) continue;

            if ([lowercaseName containsString:@"ringtone"]) {
                [ringtoneSelectors addObject:name];
            } else {
                [toneSelectors addObject:name];
            }
        }
        free(methods);
    }
    [ringtoneSelectors unionOrderedSet:toneSelectors];
    return ringtoneSelectors.array;
}

static BOOL RRToneIdentifierIsValid(id manager, NSString *identifier) {
    NSString *selectorName = @"toneWithIdentifierIsValid:";
    SEL selector = NSSelectorFromString(selectorName);
    if (manager == nil || ![manager respondsToSelector:selector]) return YES;
    BOOL (*sendMessage)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    return sendMessage(manager, selector, identifier);
}

static NSString *RRToneName(id manager, NSString *identifier) {
    id value = nil;
    SEL selector = NSSelectorFromString(@"nameForToneIdentifier:");
    if (manager != nil && [manager respondsToSelector:selector]) {
        id (*sendMessage)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        value = sendMessage(manager, selector, identifier);
    }
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : identifier;
}

static id RRToneManager(void) {
    dlopen("/System/Library/PrivateFrameworks/ToneLibrary.framework/ToneLibrary", RTLD_LAZY);
    Class managerClass = objc_getClass("TLToneManager");
    SEL sharedSelector = NSSelectorFromString(@"sharedToneManager");
    if (managerClass == Nil || ![managerClass respondsToSelector:sharedSelector]) return nil;
    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendMessage(managerClass, sharedSelector);
}

static void RRAddTone(NSMutableDictionary<NSString *, NSDictionary *> *tones,
                      id manager,
                      NSString *identifier,
                      NSString *fallbackName) {
    if (identifier.length == 0 || !RRToneIdentifierIsValid(manager, identifier)) return;
    NSString *name = RRToneName(manager, identifier);
    if ([name isEqualToString:identifier] && fallbackName.length > 0) name = fallbackName;
    tones[identifier] = @{ @"identifier": identifier, @"name": name };
}

static NSArray<NSDictionary *> *RRToneCatalog(void) {
    id manager = RRToneManager();
    NSMutableDictionary<NSString *, NSDictionary *> *tones = [NSMutableDictionary dictionary];

    for (NSString *selectorName in RRToneCatalogSelectors(object_getClass(manager))) {
        SEL selector = NSSelectorFromString(selectorName);
        if (manager == nil || ![manager respondsToSelector:selector]) continue;
        id value = RRCallObjectGetter(manager, selectorName);
        NSArray *items = RRArrayFromCatalogValue(value);
        if (items.count == 0) continue;
        for (id item in items) {
            NSString *identifier = RRIdentifierFromObject(item);
            if (identifier != nil) RRAddTone(tones, manager, identifier, nil);
        }
        if (tones.count > 0) break;
    }

    if (tones.count == 0) {
        NSArray<NSString *> *directories = @[
            @"/Library/Ringtones",
            @"/var/mobile/Media/iTunes_Control/Ringtones",
            @"/var/mobile/Library/Ringtones",
            @"/var/jb/Library/Ringtones",
        ];
        NSFileManager *fileManager = NSFileManager.defaultManager;
        for (NSString *directory in directories) {
            NSURL *root = [NSURL fileURLWithPath:directory isDirectory:YES];
            NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:root
                                                   includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:nil];
            for (NSURL *fileURL in enumerator) {
                if (![fileURL.pathExtension.lowercaseString isEqualToString:@"m4r"]) continue;
                NSNumber *isRegularFile = nil;
                [fileURL getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil];
                if (![isRegularFile boolValue]) continue;
                NSString *identifier = fileURL.URLByResolvingSymlinksInPath.path;
                NSString *name = [[fileURL.lastPathComponent stringByDeletingPathExtension]
                                  stringByReplacingOccurrencesOfString:@"_" withString:@" "];
                RRAddTone(tones, nil, identifier, name);
            }
        }
    }

    return [[tones allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                                            NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
}

#pragma mark - SIM detection

/* Each entry: @{ @"slot": @1/@2, @"label": NSString, optional @"uuid": NSString }. */
static NSArray<NSDictionary *> *RRDetectSIMs(void) {
    dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
    NSMutableDictionary<NSNumber *, NSDictionary *> *sims = [NSMutableDictionary dictionary];

    Class clientClass = objc_getClass("CoreTelephonyClient");
    SEL initWithQueue = NSSelectorFromString(@"initWithQueue:");
    SEL getInfo = NSSelectorFromString(@"getSubscriptionInfoWithError:");
    if (clientClass != Nil && [clientClass instancesRespondToSelector:initWithQueue] &&
        [clientClass instancesRespondToSelector:getInfo]) {
        static dispatch_queue_t queue;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            queue = dispatch_queue_create("com.kleinersource.randomring.telephony", DISPATCH_QUEUE_SERIAL);
        });
        id (*initClient)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id client = initClient([clientClass alloc], initWithQueue, queue);

        NSError *error = nil;
        id (*copyInfo)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
        id info = copyInfo(client, getInfo, &error);
        id contexts = RRCallObjectGetter(info, @"subscriptionsInUse") ?: RRCallObjectGetter(info, @"subscriptions");

        SEL simStatus = NSSelectorFromString(@"getSIMStatus:error:");
        for (id context in RRArrayFromCatalogValue(contexts)) {
            if ([client respondsToSelector:simStatus]) {
                NSError *statusError = nil;
                id (*copyStatus)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
                id status = copyStatus(client, simStatus, context, &statusError);
                if ([status isKindOfClass:NSString.class] && [status containsString:@"NotInserted"]) continue;
            }

            SEL slotSelector = NSSelectorFromString(@"slotID");
            if (![context respondsToSelector:slotSelector]) continue;
            long long (*readSlot)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
            NSInteger slot = (NSInteger)readSlot(context, slotSelector);
            if (slot != 1 && slot != 2) continue;

            NSMutableDictionary *sim = [NSMutableDictionary dictionaryWithObject:@(slot) forKey:@"slot"];
            id uuid = RRCallObjectGetter(context, @"uuid");
            if ([uuid isKindOfClass:NSUUID.class]) sim[@"uuid"] = [(NSUUID *)uuid UUIDString];
            id label = RRCallObjectGetter(context, @"label");
            if ([label isKindOfClass:NSString.class] && [label length] > 0) sim[@"label"] = label;
            sims[@(slot)] = sim;
        }
    }

    if (sims.count == 0) {
        /* Public fallback: one service entry per active line, keyed ...01 / ...02. */
        Class networkInfoClass = objc_getClass("CTTelephonyNetworkInfo");
        id networkInfo = networkInfoClass != Nil ? [[networkInfoClass alloc] init] : nil;
        id services = RRCallObjectGetter(networkInfo, @"serviceCurrentRadioAccessTechnology") ?:
                      RRCallObjectGetter(networkInfo, @"serviceSubscriberCellularProviders");
        if ([services isKindOfClass:NSDictionary.class]) {
            for (NSString *key in (NSDictionary *)services) {
                NSInteger slot = [key hasSuffix:@"2"] ? 2 : 1;
                sims[@(slot)] = @{ @"slot": @(slot) };
            }
        }
    }

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSNumber *slot in [sims.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableDictionary *sim = [sims[slot] mutableCopy];
        if (sim[@"label"] == nil) sim[@"label"] = [NSString stringWithFormat:@"SIM %@", slot];
        [result addObject:sim];
    }
    return result;
}

/* Lets the tweak map a call's sender identity to a slot without querying CommCenter itself. */
static void RRStoreSIMAccounts(NSArray<NSDictionary *> *sims) {
    NSMutableDictionary<NSString *, NSNumber *> *accounts = [NSMutableDictionary dictionary];
    for (NSDictionary *sim in sims) {
        if (sim[@"uuid"] != nil) accounts[[sim[@"uuid"] uppercaseString]] = sim[@"slot"];
    }
    if (accounts.count == 0) return;
    if (![RRReadPreference(RR_PREFERENCE_SIM_ACCOUNTS_KEY) isEqual:accounts]) {
        RRWritePreference(RR_PREFERENCE_SIM_ACCOUNTS_KEY, accounts);
    }
}

#pragma mark - Tone list pane

@interface RRToneListController : PSListController
@end

@implementation RRToneListController

- (NSString *)rrListKey {
    return [self.specifier propertyForKey:RRToneListKeyProperty] ?: RR_PREFERENCE_SELECTED_TONE_IDS_KEY;
}

- (PSSpecifier *)rrButtonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                             target:self
                                                                set:nil
                                                                get:nil
                                                             detail:nil
                                                               cell:PSButtonCell
                                                               edit:nil];
    SEL setter = NSSelectorFromString(@"setButtonAction:");
    if ([specifier respondsToSelector:setter]) {
        void (*sendMessage)(id, SEL, SEL) = (void (*)(id, SEL, SEL))objc_msgSend;
        sendMessage(specifier, setter, action);
    }
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers != nil) return _specifiers;

    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];
    NSArray<NSDictionary *> *tones = RRToneCatalog();

    PSSpecifier *actions = [PSSpecifier groupSpecifierWithName:nil];
    [actions setProperty:@"每次来电从已选铃声中随机抽取一首，并避开上一次的铃声。" forKey:@"footerText"];
    [specifiers addObject:actions];
    [specifiers addObject:[self rrButtonNamed:@"全选" action:@selector(rrSelectAll)]];
    [specifiers addObject:[self rrButtonNamed:@"全部取消" action:@selector(rrSelectNone)]];

    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"铃声"]];
    for (NSDictionary *tone in tones) {
        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:tone[@"name"]
                                                                 target:self
                                                                    set:@selector(setToneValue:specifier:)
                                                                    get:@selector(readToneValue:)
                                                                 detail:nil
                                                                   cell:PSSwitchCell
                                                                   edit:nil];
        [specifier setProperty:tone[@"identifier"] forKey:RRToneIdentifierProperty];
        [specifiers addObject:specifier];
    }

    if (tones.count == 0) {
        [specifiers addObject:[PSSpecifier preferenceSpecifierNamed:@"未发现可选铃声"
                                                             target:nil
                                                                set:nil
                                                                get:nil
                                                             detail:nil
                                                               cell:PSStaticTextCell
                                                               edit:nil]];
    }

    _specifiers = [specifiers copy];
    return _specifiers;
}

- (id)readToneValue:(PSSpecifier *)specifier {
    NSString *toneIdentifier = [specifier propertyForKey:RRToneIdentifierProperty];
    return @([RRReadToneList([self rrListKey]) containsObject:toneIdentifier]);
}

- (void)setToneValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *toneIdentifier = [specifier propertyForKey:RRToneIdentifierProperty];
    if (toneIdentifier == nil) return;
    NSMutableSet<NSString *> *selected = [NSMutableSet setWithArray:RRReadToneList([self rrListKey])];
    if ([value boolValue]) {
        [selected addObject:toneIdentifier];
    } else {
        [selected removeObject:toneIdentifier];
    }
    RRWriteToneList([self rrListKey], selected);
}

- (void)rrSelectAll {
    NSMutableSet<NSString *> *selected = [NSMutableSet set];
    for (NSDictionary *tone in RRToneCatalog()) [selected addObject:tone[@"identifier"]];
    RRWriteToneList([self rrListKey], selected);
    [self reloadSpecifiers];
}

- (void)rrSelectNone {
    RRWriteToneList([self rrListKey], [NSSet set]);
    [self reloadSpecifiers];
}

@end

#pragma mark - Root pane

@interface RRRootListController : PSListController
@end

@implementation RRRootListController

- (PSSpecifier *)rrSwitchSpecifierWithName:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                             target:self
                                                                set:@selector(setPreferenceValue:specifier:)
                                                                get:@selector(readPreferenceValue:)
                                                             detail:nil
                                                               cell:PSSwitchCell
                                                               edit:nil];
    [specifier setProperty:key forKey:@"key"];
    return specifier;
}

- (PSSpecifier *)rrToneListLinkNamed:(NSString *)name key:(NSString *)key {
    NSUInteger count = RRReadToneList(key).count;
    NSString *title = [NSString stringWithFormat:@"%@（已选 %lu 首）", name, (unsigned long)count];
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title
                                                             target:self
                                                                set:nil
                                                                get:nil
                                                             detail:RRToneListController.class
                                                               cell:PSLinkCell
                                                               edit:nil];
    [specifier setProperty:key forKey:RRToneListKeyProperty];
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers != nil) return _specifiers;

    NSArray<NSDictionary *> *sims = RRDetectSIMs();
    RRStoreSIMAccounts(sims);
    BOOL dualSIM = sims.count >= 2;
    BOOL perSIM = dualSIM && [RRReadPreference(RR_PREFERENCE_PER_SIM_KEY) boolValue];

    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];

    PSSpecifier *main = [PSSpecifier groupSpecifierWithName:@"来电随机铃声"];
    NSString *simSummary = sims.count == 0
        ? @"未检测到 SIM 卡。"
        : [NSString stringWithFormat:@"已检测到 %lu 张 SIM 卡。", (unsigned long)sims.count];
    [main setProperty:[simSummary stringByAppendingString:@"设置了专属铃声的联系人不受影响。"]
               forKey:@"footerText"];
    [specifiers addObject:main];
    [specifiers addObject:[self rrSwitchSpecifierWithName:@"启用随机铃声" key:RR_PREFERENCE_ENABLED_KEY]];

    if (dualSIM) {
        PSSpecifier *mode = [PSSpecifier groupSpecifierWithName:@"双卡"];
        [mode setProperty:perSIM
            ? @"两张卡分别从各自的列表中随机；无法识别来电卡槽时使用两个列表的合集。"
            : @"两张卡共用下方的全局列表。"
                   forKey:@"footerText"];
        [specifiers addObject:mode];
        [specifiers addObject:[self rrSwitchSpecifierWithName:@"双卡使用独立列表" key:RR_PREFERENCE_PER_SIM_KEY]];
    }

    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"参与随机的铃声"]];
    if (perSIM) {
        for (NSDictionary *sim in sims) {
            BOOL first = [sim[@"slot"] integerValue] == 1;
            NSString *name = [NSString stringWithFormat:@"卡 %@ · %@", sim[@"slot"], sim[@"label"]];
            [specifiers addObject:[self rrToneListLinkNamed:name
                                                         key:first ? RR_PREFERENCE_SIM1_TONE_IDS_KEY
                                                                   : RR_PREFERENCE_SIM2_TONE_IDS_KEY]];
        }
    } else {
        [specifiers addObject:[self rrToneListLinkNamed:@"全局列表" key:RR_PREFERENCE_SELECTED_TONE_IDS_KEY]];
    }

    PSSpecifier *about = [PSSpecifier groupSpecifierWithName:nil];
    [about setProperty:[NSString stringWithFormat:@"RandomRing v%s\n开发者 %s", RR_VERSION, RR_AUTHOR]
                forKey:@"footerText"];
    [about setProperty:@1 forKey:@"footerAlignment"]; /* NSTextAlignmentCenter */
    [specifiers addObject:about];

    _specifiers = [specifiers copy];
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id value = key != nil ? RRReadPreference(key) : nil;
    return value ?: @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:RR_PREFERENCE_ENABLED_KEY] || [key isEqualToString:RR_PREFERENCE_PER_SIM_KEY]) {
        RRWritePreference(key, @([value boolValue]));
    }
    if ([key isEqualToString:RR_PREFERENCE_PER_SIM_KEY]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_specifiers = nil;
            [self reloadSpecifiers];
        });
    }
}

@end
