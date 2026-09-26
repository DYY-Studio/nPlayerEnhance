// nPlayer 3.13.0 private API declarations.
//
// Compile-time placeholders only: the real classes are looked up by name at
// runtime. Names, inheritance and property types follow nPlayer.h (ipsw
// class-dump); method prototypes that the dump does not carry (return types,
// parameters) follow the observed call sites.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface MediaPlayerConfig : NSObject
- (void)setObject:(id)object forKey:(id)key;
@end

@interface MediaPlayerController : NSObject
- (BOOL)showSubtitles;
- (void)setShowSubtitles:(BOOL)showSubtitles;
- (void)updateSubtitles;
- (void)onRenderSubtitle;
- (void)subtitleDidChangeWithBitmap:(id)bitmap;
@end

@interface nPlayerView : UIView
- (NSInteger)decoder;
- (void)mediaPlayerDecoderChanged:(BOOL)hardware;
@end

@interface GlobalSettingsBaseController : UIViewController
- (instancetype)initWithItems:(NSArray *)items;
- (instancetype)initWithSections:(NSArray *)sections;
@end
