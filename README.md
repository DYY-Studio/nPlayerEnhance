# nPlayer iOS Enhance

> A small tribute to nPlayer, an exceptionally well-designed player that has served us reliably for years.

Raises `nPlayer`'s subtitle refresh rate and exposes it as a settings item.

No jailbreak. No inline hooks.

> [!Warning]
>
> **Vibe Coding Project**

## What it does

### Subtitle Refresh Rate
- Hooks `-[CADisplayLink setFrameInterval:]` on nPlayer's subtitle render thread. nPlayer hard-codes `4` (≈15 Hz); when a rate is configured, the tweak substitutes the matching integer divisor of the display's maximum refresh rate.
- Injects a **Subtitle Refresh Rate** row at the top of nPlayer's Subtitle settings page. The row pushes a native single-choice list; each option stores its value under the `SubtitleRefreshRate` key in `NSUserDefaults`.

With no stored value the tweak leaves `frameInterval` at nPlayer's original value. The available options are the integer divisors of `UIScreen.mainScreen.maximumFramesPerSecond` (for example 15/30/60 on a 60 Hz device).

### Live Settings Sync
- nPlayer's `-[MediaPlayerConfig setObject:forKey:]` writes values without KVO notifications, so the per-item config observer caches a snapshot and never refreshes while playing. The tweak wraps that setter and emits `willChange`/`didChange` for `ShowSubtitles`, `TextToSpeechEnabled`, `TextToSpeechSpeakingRate` and `TextToSpeechLanguage`, so toggling Show Subtitles or TTS during playback takes effect immediately.

Recommend to use with `nPlayerLibassBridge`, which brings modern ASS/SSA rendering to this great player.

## Requirements

- iOS 13.0+ (nPlayer 3.13.0 required)
- Injectable nPlayer iOS
- A hooking runtime providing `MSHookMessageEx` (Cydia Substrate, Substitute or ElleKit)
  - Jailbroken
  - TrollStore (TrollFools)
  - LiveContainer (has ElleKit already)
  - Sideloadly

## Development

Theos

## Build

```sh
make package
```

## License

MIT — see [LICENSE](LICENSE).
