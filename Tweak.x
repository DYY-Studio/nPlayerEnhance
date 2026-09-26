#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import "nPlayerPrivate.h"

typedef void (*MSHookMessageEx_t)(Class cls, SEL sel, IMP imp, IMP *result);

static MSHookMessageEx_t ResolveMSHookMessageEx(void) {
    return (MSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
}

static NSString *const kPrefKey = @"SubtitleRefreshRate";

static NSString *NPLocalized(NSString *key, NSString *fallback) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:fallback table:nil];
}

static NSString *NPLanguageCode(void) {
    NSString *code = [NSBundle mainBundle].preferredLocalizations.firstObject;
    if (!code) {
        return @"en";
    }
    return code;
}

static NSString *NPTitleSubtitleRefreshRate(void) {
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"en": @"Subtitle Refresh Rate",
            @"zh-Hans": @"字幕刷新率",
            @"zh-Hant": @"字幕更新率",
            @"ja": @"字幕更新頻度",
            @"ko": @"자막 갱신 빈도",
            @"de": @"Untertitel-Aktualisierungsrate",
            @"fr": @"Fréquence de rafraîchissement des sous-titres",
            @"es": @"Frecuencia de actualización de subtítulos",
            @"ru": @"Частота обновления субтитров",
            @"ar": @"معدل تحديث الترجمة النصية",
        };
    });
    NSString *value = table[NPLanguageCode()];
    return value ?: table[@"en"];
}

static NSInteger ScreenMaxFPS(void) {
    static NSInteger cached = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger fps = 60;
        if (@available(iOS 10.0, *)) {
            NSInteger v = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
            if (v > 0) {
                fps = v;
            }
        }
        cached = fps;
    });
    return cached;
}

static NSInteger ConfiguredRefreshRate(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kPrefKey];
    if ([v respondsToSelector:@selector(integerValue)]) {
        NSInteger n = [v integerValue];
        if (n > 0) {
            return n;
        }
    }
    return 0;
}

static NSArray<NSNumber *> *AvailableRefreshRates(void) {
    NSInteger base = ScreenMaxFPS();
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    for (NSNumber *n in @[@15, @24, @30, @50, @60, @90, @120]) {
        NSInteger v = n.integerValue;
        if (v <= base && base % v == 0) {
            [out addObject:n];
        }
    }
    return out;
}

static NSString *RefreshRateDetail(void) {
    NSInteger fps = ConfiguredRefreshRate();
    if (fps <= 0) {
        return NPLocalized(@"Default", @"Default");
    }
    return [NSString stringWithFormat:@"%ld Hz", (long)fps];
}

static void PushRefreshRatePage(id host) {
    UINavigationController *navigationController = [host navigationController];
    Class controllerClass = objc_getClass("GlobalSettingsBaseController");
    if (!navigationController || !controllerClass || !class_getInstanceMethod(controllerClass, @selector(initWithItems:))) {
        return;
    }

    __weak id weakHost = host;
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithObject:@0];
    [values addObjectsFromArray:AvailableRefreshRates()];

    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:values.count];
    for (NSNumber *value in values) {
        NSInteger fps = value.integerValue;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"Title"] = fps > 0 ? [NSString stringWithFormat:@"%ld Hz", (long)fps]
                                : NPLocalized(@"Default", @"Default");
        row[@"CellHandler"] = ^(UITableView *tableView, UITableViewCell *cell) {
            cell.accessoryType = ConfiguredRefreshRate() == fps ? UITableViewCellAccessoryCheckmark
                                                               : UITableViewCellAccessoryNone;
        };
        row[@"SelectionHandler"] = ^(UITableView *tableView, NSDictionary *item) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            if (fps > 0) {
                [defaults setInteger:fps forKey:kPrefKey];
            } else {
                [defaults removeObjectForKey:kPrefKey];
            }
            [defaults synchronize];
            [[weakHost navigationController] popViewControllerAnimated:YES];
        };
        [items addObject:row];
    }

    GlobalSettingsBaseController *page = [[controllerClass alloc] initWithItems:items];
    page.title = NPTitleSubtitleRefreshRate();
    [navigationController pushViewController:page animated:YES];
}

static void (*orig_setFrameInterval)(id, SEL, NSInteger);

static void hook_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    if (interval == 4) {
        NSInteger fps = ConfiguredRefreshRate();
        if (fps > 0) {
            NSInteger base = ScreenMaxFPS();
            NSInteger divisor = (base + fps / 2) / fps;
            if (divisor < 1) {
                divisor = 1;
            }
            interval = divisor;
        }
    }
    if (orig_setFrameInterval) {
        orig_setFrameInterval(self, _cmd, interval);
    }
}

static id (*orig_initWithSections)(id, SEL, id);

static id hook_initWithSections(id self, SEL _cmd, id sections) {
    BOOL isSubtitlePage = NO;
    if ([sections isKindOfClass:[NSMutableArray class]] && [sections count] > 0) {
        for (NSUInteger i = 0; i < [sections count]; i++) {
            id section = [sections objectAtIndex:i];
            if (![section isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            id title = section[@"Title"];
            if ([title isKindOfClass:[NSString class]] && [title isEqualToString:@"SSA/ASS"]) {
                isSubtitlePage = YES;
                break;
            }
        }
        if (isSubtitlePage && [[sections objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *topSection = [[sections objectAtIndex:0] mutableCopy];
            id rawItems = topSection[@"Items"];
            if ([rawItems isKindOfClass:[NSArray class]]) {
                __weak id weakSelf = self;
                NSMutableDictionary *row = [NSMutableDictionary dictionary];
                row[@"Title"] = NPTitleSubtitleRefreshRate();
                row[@"AccessoryType"] = @1;
                row[@"CellHandler"] = ^(UITableView *tableView, UITableViewCell *cell) {
                    cell.detailTextLabel.text = RefreshRateDetail();
                };
                row[@"SelectionHandler"] = ^(UITableView *tableView, NSDictionary *item) {
                    PushRefreshRatePage(weakSelf);
                };

                NSMutableArray *items = [rawItems mutableCopy];
                [items addObject:row];
                topSection[@"Items"] = items;
                [sections replaceObjectAtIndex:0 withObject:topSection];
            }
        }
    }
    if (orig_initWithSections) {
        return orig_initWithSections(self, _cmd, sections);
    }
    return self;
}

static NSString *KVOKeyForPlayerConfigKey(NSString *key) {
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"ShowSubtitles": @"showSubtitles",
            @"TextToSpeechEnabled": @"textToSpeechEnabled",
            @"TextToSpeechSpeakingRate": @"textToSpeechSpeakingRate",
            @"TextToSpeechLanguage": @"textToSpeechLanguage",
        };
    });
    return table[key];
}

static void (*orig_setObjectForKey)(id, SEL, id, id);

static void hook_setObjectForKey(id self, SEL _cmd, id object, id key) {
    NSString *kvoKey = nil;
    if ([key isKindOfClass:[NSString class]]) {
        kvoKey = KVOKeyForPlayerConfigKey(key);
    }
    if (kvoKey) {
        [self willChangeValueForKey:kvoKey];
    }
    if (orig_setObjectForKey) {
        orig_setObjectForKey(self, _cmd, object, key);
    }
    if (kvoKey) {
        [self didChangeValueForKey:kvoKey];
    }
}

static const void *kSubtitleRefreshPendingKey = &kSubtitleRefreshPendingKey;

static BOOL ControllerShowsSubtitles(id controller) {
    if (![controller respondsToSelector:@selector(showSubtitles)]) {
        return NO;
    }
    return [(MediaPlayerController *)controller showSubtitles];
}

static void ForceSubtitleRefresh(id controller) {
    if ([controller respondsToSelector:@selector(updateSubtitles)]) {
        [(MediaPlayerController *)controller updateSubtitles];
    }

    Ivar subtitlesIvar = class_getInstanceVariable(object_getClass(controller), "_subtitles");
    Class subtitleClass = objc_getClass("Subtitle");
    Ivar bitmapIvar = subtitleClass ? class_getInstanceVariable(subtitleClass, "_bitmap") : NULL;
    if (!subtitlesIvar || !bitmapIvar || ![controller respondsToSelector:@selector(subtitleDidChangeWithBitmap:)]) {
        return;
    }

    NSArray *subtitles = object_getIvar(controller, subtitlesIvar);
    if (![subtitles isKindOfClass:[NSArray class]]) {
        return;
    }
    for (id subtitle in subtitles) {
        id bitmap = object_getIvar(subtitle, bitmapIvar);
        if (bitmap) {
            [(MediaPlayerController *)controller subtitleDidChangeWithBitmap:bitmap];
        }
    }
}

static void (*orig_setShowSubtitles)(id, SEL, BOOL);

static void hook_setShowSubtitles(id self, SEL _cmd, BOOL value) {
    BOOL wasShowing = ControllerShowsSubtitles(self);
    if (orig_setShowSubtitles) {
        orig_setShowSubtitles(self, _cmd, value);
    }
    if (value && !wasShowing) {
        objc_setAssociatedObject(self, kSubtitleRefreshPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!value) {
        objc_setAssociatedObject(self, kSubtitleRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void (*orig_onRenderSubtitle)(id, SEL);

static void hook_onRenderSubtitle(id self, SEL _cmd) {
    if (orig_onRenderSubtitle) {
        orig_onRenderSubtitle(self, _cmd);
    }
    if (!objc_getAssociatedObject(self, kSubtitleRefreshPendingKey)) {
        return;
    }
    objc_setAssociatedObject(self, kSubtitleRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (ControllerShowsSubtitles(self)) {
        ForceSubtitleRefresh(self);
    }
}

static void InstallHooks(void) {
    MSHookMessageEx_t hook = ResolveMSHookMessageEx();
    if (!hook) {
        NSLog(@"[nPlayerEnhance] MSHookMessageEx unavailable, tweak inactive");
        return;
    }

    Class displayLink = objc_getClass("CADisplayLink");
    if (displayLink && class_getInstanceMethod(displayLink, @selector(setFrameInterval:))) {
        hook(displayLink, @selector(setFrameInterval:), (IMP)hook_setFrameInterval, (IMP *)&orig_setFrameInterval);
    }

    Class settingsBase = objc_getClass("GlobalSettingsBaseController");
    if (settingsBase && class_getInstanceMethod(settingsBase, @selector(initWithSections:))) {
        hook(settingsBase, @selector(initWithSections:), (IMP)hook_initWithSections, (IMP *)&orig_initWithSections);
    }

    Class playerConfig = objc_getClass("MediaPlayerConfig");
    if (playerConfig && class_getInstanceMethod(playerConfig, @selector(setObject:forKey:))) {
        hook(playerConfig, @selector(setObject:forKey:), (IMP)hook_setObjectForKey, (IMP *)&orig_setObjectForKey);
    }

    Class playerController = objc_getClass("MediaPlayerController");
    if (playerController && class_getInstanceMethod(playerController, @selector(setShowSubtitles:))) {
        hook(playerController, @selector(setShowSubtitles:), (IMP)hook_setShowSubtitles, (IMP *)&orig_setShowSubtitles);
    }
    if (playerController && class_getInstanceMethod(playerController, @selector(onRenderSubtitle))) {
        hook(playerController, @selector(onRenderSubtitle), (IMP)hook_onRenderSubtitle, (IMP *)&orig_onRenderSubtitle);
    }
}

%ctor {
    @autoreleasepool {
        InstallHooks();
    }
}
