# nPlayer iOS Enhance

> A small tribute to nPlayer, an exceptionally well-designed player that has served us reliably for years.

> [!Warning]
>
> **Vibe Coding Project**

Raises `nPlayer`'s subtitle refresh rate and exposes it as a settings item, and more.

No jailbreak. No inline hooks. Design for sideloading and non-JIT LiveContainer.

## What it does

### Subtitle Refresh Rate
- Hooks `-[CADisplayLink setFrameInterval:]` on nPlayer's subtitle render thread. nPlayer hard-codes `4` (≈15 Hz); when a rate is configured, the tweak substitutes the matching integer divisor of the display's maximum refresh rate.
- Injects a **Subtitle Refresh Rate** row at the top of nPlayer's Subtitle settings page. The row pushes a native single-choice list; each option stores its value under the `SubtitleRefreshRate` key in `NSUserDefaults`.

With no stored value the tweak leaves `frameInterval` at nPlayer's original value. The available options are the integer divisors of `UIScreen.mainScreen.maximumFramesPerSecond` (for example 15/30/60 on a 60 Hz device).

### Live Settings Sync
- nPlayer's `-[MediaPlayerConfig setObject:forKey:]` writes values without KVO notifications, so the per-item config observer caches a snapshot and never refreshes while playing. The tweak wraps that setter and emits `willChange`/`didChange` for `ShowSubtitles`, `TextToSpeechEnabled`, `TextToSpeechSpeakingRate` and `TextToSpeechLanguage`, so toggling Show Subtitles or TTS during playback takes effect immediately.

### Subtitle Toggle Refresh
- Hiding subtitles clears the view but leaves nPlayer's internal "current cue is active" state untouched, so turning subtitles back on stayed blank until the next cue. The tweak marks the off→on transition and, right after the next render tick recomputes the current cue, re-pushes the active text and bitmap so the correct subtitle appears immediately.

### Decoder Switch Indicator
- Switching S/W → H/W during playback left the control bar's `H/W`/`S/W` label on the old value: nPlayer's H/W decoder factory posts `mediaPlayerDecoderChanged:` *before* installing the new decoder, and the producer re-reads the current decoder on the main queue, so it captures the outdated one and never notifies again. The tweak defers that notification until `[nPlayerView decoder]` reports H/W (16 ms steps, ~160 ms cap) and then lets the original re-read. S/W → H/W now updates once with no stale flash; the H/W → S/W path is untouched.

Recommend to use with `nPlayerModernBridge`, which brings modern ASS/SSA rendering to this great player.

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
