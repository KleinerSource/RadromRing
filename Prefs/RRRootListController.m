#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

#import "../core/RRPreferences.h"

static NSString *const RRToneIdentifierProperty = @"rrToneIdentifier";

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

static id RRCallObjectGetter(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    id (*sendMessage)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendMessage(object, selector);
}

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

- (NSArray *)specifiers {
    if (_specifiers != nil) return _specifiers;

    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];
    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"来电随机铃声"]];
    [specifiers addObject:[self rrSwitchSpecifierWithName:@"启用随机铃声"
                                                      key:RR_PREFERENCE_ENABLED_KEY]];
    [specifiers addObject:[PSSpecifier groupSpecifierWithName:@"参与随机的铃声"]];

    NSArray<NSDictionary *> *tones = RRToneCatalog();
    for (NSDictionary *tone in tones) {
        PSSpecifier *specifier = [self rrSwitchSpecifierWithName:tone[@"name"]
                                                            key:RR_PREFERENCE_SELECTED_TONE_IDS_KEY];
        [specifier setProperty:tone[@"identifier"] forKey:RRToneIdentifierProperty];
        [specifiers addObject:specifier];
    }

    if (tones.count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"未发现可选铃声"
                                                             target:nil
                                                                set:nil
                                                                get:nil
                                                             detail:nil
                                                               cell:PSStaticTextCell
                                                               edit:nil];
        [specifiers addObject:empty];
    }

    _specifiers = [specifiers copy];
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *toneIdentifier = [specifier propertyForKey:RRToneIdentifierProperty];
    if (toneIdentifier != nil) {
        NSArray *selectedToneIDs = RRReadPreference(RR_PREFERENCE_SELECTED_TONE_IDS_KEY);
        return @([selectedToneIDs containsObject:toneIdentifier]);
    }

    NSString *key = [specifier propertyForKey:@"key"];
    id value = key != nil ? RRReadPreference(key) : nil;
    if ([key isEqualToString:RR_PREFERENCE_ENABLED_KEY]) return value ?: @NO;
    return value;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *toneIdentifier = [specifier propertyForKey:RRToneIdentifierProperty];
    if (toneIdentifier != nil) {
        NSArray *current = RRReadPreference(RR_PREFERENCE_SELECTED_TONE_IDS_KEY);
        NSMutableSet<NSString *> *selected = [NSMutableSet set];
        if ([current isKindOfClass:NSArray.class]) {
            for (id identifier in current) {
                if ([identifier isKindOfClass:NSString.class]) [selected addObject:identifier];
            }
        }
        if ([value boolValue]) {
            [selected addObject:toneIdentifier];
        } else {
            [selected removeObject:toneIdentifier];
        }
        NSArray *sortedSelection = [[selected allObjects] sortedArrayUsingSelector:@selector(compare:)];
        RRWritePreference(RR_PREFERENCE_SELECTED_TONE_IDS_KEY, sortedSelection);
        return;
    }

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:RR_PREFERENCE_ENABLED_KEY]) {
        RRWritePreference(key, @([value boolValue]));
    }
}

@end
