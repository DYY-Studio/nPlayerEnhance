#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/message.h>

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

/* ---- Post Processing: scaling kernel ------------------------------------
 *
 * The bridge reads these preferences when it generates a shader, so a change
 * applies to the next video rather than the one playing. */

static NSString *const kScaleKernelPrefKey = @"PPVideoScaleKernel";
static NSString *const kScaleKernelUpPrefKey = @"PPVideoScaleKernelUpscale";
static NSString *const kAntiRingingPrefKey = @"PPVideoAntiRinging";

/* The app adds a private UISwitch helper; it is not in the SDK. */
@interface UIControl (nPlayerEnhance)
- (void)addActionHandler:(void (^)(id sender))handler forControlEvents:(UIControlEvents)events;
@end

/* BOOL-returning getter reached through respondsToSelector:. */
@protocol NPScaleKernelPlayer
- (BOOL)videoPostProcessingEnabled;
@end

/* The menu rows only mean something when the bridge that reads these
 * preferences is loaded. Its export exists only in that dylib, so a missing or
 * failed load hides the rows instead of leaving settings that change nothing. */
static BOOL ScaleKernelBridgeLoaded(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlsym(RTLD_DEFAULT, "npa_renderer_pp_hdr_shader_source") != NULL;
    });
    return loaded;
}

static NSInteger ConfiguredKernel(NSString *key) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static NSInteger ConfiguredScaleKernel(void) {
    return ConfiguredKernel(kScaleKernelPrefKey);
}

static NSString *ScaleKernelName(NSInteger kernel) {
    switch (kernel) {
        case 1: return @"Catmull-Rom";
        case 2: return @"Mitchell";
        case 3: return @"Bicubic A=-0.75";
        case 4: return @"Lanczos2";
        case 5: return @"Lanczos3";
        case 6: return @"B-Spline";
        case 7: return @"Spline36";
        case 8: return @"Spline64";
        default: return NPLocalized(@"Default", @"Default");
    }
}

static NSString *NPTitleScaleKernel(void) {
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"en": @"Downscaling Kernel",
            @"zh-Hans": @"缩小算法",
            @"zh-Hant": @"縮小演算法",
            @"ja": @"ダウンスケーリング",
            @"ko": @"다운스케일링 커널",
            @"de": @"Herunterskalierung",
            @"fr": @"Noyau de réduction",
            @"es": @"Kernel de reducción",
            @"ru": @"Ядро уменьшения",
            @"ar": @"نواة التصغير",
        };
    });
    NSString *value = table[NPLanguageCode()];
    return value ?: table[@"en"];
}

static NSString *NPTitleScaleKernelUp(void) {
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"en": @"Upscaling Kernel",
            @"zh-Hans": @"放大算法",
            @"zh-Hant": @"放大演算法",
            @"ja": @"アップスケーリング",
            @"ko": @"업스케일링 커널",
            @"de": @"Hochskalierungskernel",
            @"fr": @"Noyau d'agrandissement",
            @"es": @"Kernel de escalado",
            @"ru": @"Ядро увеличения",
            @"ar": @"نواة التكبير",
        };
    });
    NSString *value = table[NPLanguageCode()];
    return value ?: table[@"en"];
}

static NSString *NPTitleAntiRinging(void) {
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"en": @"Anti-Ringing",
            @"zh-Hans": @"抗振铃",
            @"zh-Hant": @"抗振鈴",
            @"ja": @"リンギング抑制",
            @"ko": @"링잉 억제",
            @"de": @"Ringartefakte",
            @"fr": @"Anti-résonance",
            @"es": @"Antirretumbo",
            @"ru": @"Подавление звона",
            @"ar": @"منع الرنين",
        };
    });
    NSString *value = table[NPLanguageCode()];
    return value ?: table[@"en"];
}

/* The app's own single-choice sub-pages (Color Space, Deinterlacing) use plain
 * SettingsBaseController: alloc/init + setItems: + setTitle:. That class has no
 * grouped section header band, which is why they show no blank strip on top. */
static void PushScaleKernelPage(id host, NSString *key, NSString *title) {
    UINavigationController *navigationController = [host navigationController];
    Class controllerClass = objc_getClass("SettingsBaseController");
    if (!navigationController || !controllerClass
        || !class_getInstanceMethod(controllerClass, @selector(setItems:))) {
        return;
    }

    __weak id weakHost = host;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSInteger kernel = 0; kernel <= 8; kernel++) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"Title"] = ScaleKernelName(kernel);
        row[@"CellHandler"] = ^(UITableView *tableView, UITableViewCell *cell) {
            cell.accessoryType = ConfiguredKernel(key) == kernel ? UITableViewCellAccessoryCheckmark
                                                                : UITableViewCellAccessoryNone;
        };
        row[@"SelectionHandler"] = ^(UITableView *tableView, NSDictionary *item) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            if (kernel > 0) {
                [defaults setInteger:kernel forKey:key];
            } else {
                [defaults removeObjectForKey:key];
            }
            [defaults synchronize];
            [[weakHost navigationController] popViewControllerAnimated:YES];
        };
        [items addObject:row];
    }

    id page = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(alloc)), @selector(init));
    if (!page) {
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(page, @selector(setItems:), items);
    ((void (*)(id, SEL, id))objc_msgSend)(page, @selector(setTitle:), title);
    [navigationController pushViewController:page animated:YES];
}

static void (*orig_ppRefresh)(id, SEL);

/* The page rebuilds its item list on init, on setMediaPlayer: and on every
 * toggle, and it only builds its six dependent rows while Post Processing is
 * on. Appending here inherits that exact gating: with PP off the page has one
 * row and ours are absent, which is the app's own convention rather than
 * disabled rows of our own invention. */
static void hook_ppRefresh(id self, SEL _cmd) {
    if (orig_ppRefresh) {
        orig_ppRefresh(self, _cmd);
    }
    if (!ScaleKernelBridgeLoaded()) {
        return;
    }
    /* The page's own rows are gated on this flag; ours have to match, or the
     * settings stay visible while nothing can consume them. */
    if (![self respondsToSelector:@selector(mediaPlayer)]) {
        return;
    }
    id player = [self performSelector:@selector(mediaPlayer)];
    if (!player || ![player respondsToSelector:@selector(videoPostProcessingEnabled)]) {
        return;
    }
    if (![(id<NPScaleKernelPlayer>)player videoPostProcessingEnabled]) {
        return;
    }
    if (![self respondsToSelector:@selector(items)]
        || ![self respondsToSelector:@selector(setItems:)]) {
        return;
    }
    id current = [self performSelector:@selector(items)];
    if (![current isKindOfClass:[NSArray class]]) {
        return;
    }

    __weak id weakSelf = self;
    NSMutableArray *items = [current mutableCopy];

    NSMutableDictionary *down = [NSMutableDictionary dictionary];
    down[@"Title"] = NPTitleScaleKernel();
    down[@"AccessoryType"] = @1;
    down[@"CellHandler"] = ^(UITableView *tableView, UITableViewCell *cell) {
        cell.detailTextLabel.text = ScaleKernelName(ConfiguredScaleKernel());
    };
    down[@"SelectionHandler"] = ^(UITableView *tableView, NSDictionary *item) {
        PushScaleKernelPage(weakSelf, kScaleKernelPrefKey, NPTitleScaleKernel());
    };
    [items addObject:down];

    /* The upscaling choice falls back to the downscaling one, so an unset key
     * shows what the bridge will actually use. */
    NSMutableDictionary *up = [NSMutableDictionary dictionary];
    up[@"Title"] = NPTitleScaleKernelUp();
    up[@"AccessoryType"] = @1;
    up[@"CellHandler"] = ^(UITableView *tableView, UITableViewCell *cell) {
        NSInteger chosen = ConfiguredKernel(kScaleKernelUpPrefKey);
        cell.detailTextLabel.text = ScaleKernelName(chosen ? chosen : ConfiguredScaleKernel());
    };
    up[@"SelectionHandler"] = ^(UITableView *tableView, NSDictionary *item) {
        PushScaleKernelPage(weakSelf, kScaleKernelUpPrefKey, NPTitleScaleKernelUp());
    };
    [items addObject:up];

    /* Same shape the app uses for its own switch row: build the UISwitch in
     * the cell handler, attach it as the accessory, and turn selection off. */
    NSMutableDictionary *ring = [NSMutableDictionary dictionary];
    ring[@"Title"] = NPTitleAntiRinging();
    ring[@"CellHandler"] = ^(UITableView *tableView, UITableViewCell *cell) {
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.on = ConfiguredKernel(kAntiRingingPrefKey) != 0;
        [toggle addActionHandler:^(UISwitch *sender) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            if (sender.isOn) {
                [defaults setInteger:1 forKey:kAntiRingingPrefKey];
            } else {
                [defaults removeObjectForKey:kAntiRingingPrefKey];
            }
            [defaults synchronize];
        } forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    };
    [items addObject:ring];

    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setItems:), items);
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

static void (*orig_mediaPlayerDecoderChanged)(id, SEL, BOOL);

// nPlayer's H/W factory notifies before it installs the new decoder, so the
// notification's main-queue block re-reads the still-current S/W decoder and
// writes a stale label. Defer the notification until [nPlayerView decoder]
// reports 2 (H/W), then let the original re-read; on timeout notify anyway so
// the label still reflects the real state.
static const NSUInteger kDecoderNotifyMaxAttempts = 10;

static void PollDecoderThenNotify(nPlayerView *view, SEL _cmd, NSUInteger attempt) {
    if ([view decoder] == 2 || attempt >= kDecoderNotifyMaxAttempts) {
        if (orig_mediaPlayerDecoderChanged) {
            orig_mediaPlayerDecoderChanged(view, _cmd, YES);
        }
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        PollDecoderThenNotify(view, _cmd, attempt + 1);
    });
}

static void hook_mediaPlayerDecoderChanged(id self, SEL _cmd, BOOL hardware) {
    if (!hardware) {
        if (orig_mediaPlayerDecoderChanged) {
            orig_mediaPlayerDecoderChanged(self, _cmd, hardware);
        }
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        PollDecoderThenNotify((nPlayerView *)self, _cmd, 0);
    });
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

    Class ppSettings = objc_getClass("MediaPlayerVideoPostProcessingSettingController");
    if (ppSettings && class_getInstanceMethod(ppSettings, @selector(refresh))) {
        hook(ppSettings, @selector(refresh), (IMP)hook_ppRefresh, (IMP *)&orig_ppRefresh);
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

    Class playerView = objc_getClass("nPlayerView");
    if (playerView && class_getInstanceMethod(playerView, @selector(mediaPlayerDecoderChanged:))) {
        hook(playerView, @selector(mediaPlayerDecoderChanged:), (IMP)hook_mediaPlayerDecoderChanged, (IMP *)&orig_mediaPlayerDecoderChanged);
    }
}

%ctor {
    @autoreleasepool {
        InstallHooks();
    }
}
