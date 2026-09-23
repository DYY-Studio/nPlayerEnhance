#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

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

static void PresentRefreshRatePicker(UITableView *tableView, NSMutableDictionary *row) {
    UIResponder *host = tableView;
    while (host && ![host isKindOfClass:[UIViewController class]]) {
        host = host.nextResponder;
    }
    if (!host) {
        return;
    }

    NSString *title = NPTitleSubtitleRefreshRate();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    NSInteger current = ConfiguredRefreshRate();
    for (NSNumber *n in AvailableRefreshRates()) {
        NSInteger v = n.integerValue;
        NSString *itemTitle = [NSString stringWithFormat:@"%ld Hz", (long)v];
        if (v == current) {
            itemTitle = [itemTitle stringByAppendingString:@" ✓"];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:itemTitle
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kPrefKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            row[@"DetailText"] = RefreshRateDetail();
            [tableView reloadData];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:NPLocalized(@"Default", @"Default")
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPrefKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        row[@"DetailText"] = RefreshRateDetail();
        [tableView reloadData];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:NPLocalized(@"Cancel", @"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = tableView;
        sheet.popoverPresentationController.sourceRect = tableView.bounds;
    }
    [(UIViewController *)host presentViewController:sheet animated:YES completion:nil];
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
                NSMutableDictionary *row = [NSMutableDictionary dictionary];
                row[@"Title"] = NPTitleSubtitleRefreshRate();
                row[@"DetailText"] = RefreshRateDetail();
                row[@"SelectionHandler"] = ^(UITableView *tableView, NSDictionary *item) {
                    PresentRefreshRatePicker(tableView, (NSMutableDictionary *)item);
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

static void InstallHooks(void) {
    MSHookMessageEx_t hook = ResolveMSHookMessageEx();
    if (!hook) {
        NSLog(@"[nPlayerEnhance] MSHookMessageEx unavailable, tweak inactive");
        return;
    }

    Class displayLink = objc_getClass("CADisplayLink");
    SEL setFrameInterval = NSSelectorFromString(@"setFrameInterval:");
    if (displayLink && class_getInstanceMethod(displayLink, setFrameInterval)) {
        hook(displayLink, setFrameInterval, (IMP)hook_setFrameInterval, (IMP *)&orig_setFrameInterval);
    }

    Class settingsBase = objc_getClass("GlobalSettingsBaseController");
    SEL initWithSections = NSSelectorFromString(@"initWithSections:");
    if (settingsBase && class_getInstanceMethod(settingsBase, initWithSections)) {
        hook(settingsBase, initWithSections, (IMP)hook_initWithSections, (IMP *)&orig_initWithSections);
    }
}

%ctor {
    @autoreleasepool {
        InstallHooks();
    }
}
