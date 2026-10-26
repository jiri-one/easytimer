# EasyTimer

A simple interval timer for Android, Linux and the browser. EasyTimer is a Flutter
rewrite of [Interval Timer](https://github.com/randombits-dev/interval-timer), with
large controls, system light/dark colours and an interface suited to e-ink screens.

Set **Active**, **Rest** and **Sets**, then press Start. Preparation lasts five
seconds. An empty or zero set count repeats indefinitely. The last settings and
volume are saved locally. Volume uses whole percentages from 0 to 100. English,
Czech, Catalan, Spanish and French follow the system language, with English as
the fallback.

Space starts, pauses or resumes; Escape stops; Up/Down change the timer volume by
5%. Android's volume keys always control media volume. The timer does not request
audio focus, so music and podcasts can keep playing.

Pausing preparation restarts its five seconds on resume. Pausing an active set
preserves its remaining time. Resuming from rest skips the rest of that break and
prepares the next set. The screen stays awake while the timer is shown, including
while paused, where the platform allows it. On Linux this uses the desktop's
Inhibit portal through `wakelock_plus`; support depends on the desktop portal
backend.

## Build and test

Use Flutter 3.47.7 / Dart 3.13.5, an Android SDK for APK builds, and the standard
Flutter Linux build dependencies plus GStreamer development headers
(`libgstreamer1.0-dev` and `libgstreamer-plugins-base1.0-dev` on Debian/Ubuntu)
for desktop builds. From `app/`:

```sh
flutter pub get
flutter analyze
flutter test
flutter test --platform chrome test/web_platform_test.dart test/platform_parity_browser_test.dart
./tool/build_web.sh
./tool/build_web.sh --wasm
flutter build linux --release
flutter build apk --release
```

The web output is `app/build/web/`; serve it over HTTPS (localhost also works for
development). Screen Wake Lock requires a secure origin and may be denied by the
browser. WASM works without cross-origin isolation using its single-threaded
renderer, including on GitHub Pages.

Linux audio needs GStreamer with its base and good plugins
(`gstreamer1.0-plugins-base` and `gstreamer1.0-plugins-good` on Debian/Ubuntu).
Flatpak supplies these through the Freedesktop runtime and uses
`--socket=pulseaudio` for host audio. Audio is decoded locally; no online services,
proprietary audio SDKs or Play services are used. See
[packaging instructions](packaging/README.md) for releases and installation.

The committed golden tests load the bundled fonts and cover 824×1648 physical
pixels at DPR 1.5, 1.875 and 2.5, 420×760 and 640×400 desktop windows, and a 1440×900 browser.
Generated localization bindings are tracked, as in EasyDict. Regenerate them
with `flutter gen-l10n` after editing the ARB files; CI checks the result.
After an intentional visual change, regenerate goldens with:

```sh
flutter test test/golden_test.dart --update-goldens
```

## Implementation

`app/lib/timer_engine.dart` derives the current phase, set, display and sound
boundaries from a monotonic clock. Android and Linux read `CLOCK_BOOTTIME`
through FFI, including suspend; the web uses `performance.now()`. Late callbacks
do not extend a phase or replay expired alarms. Timer text updates on displayed
second or state changes, with a separate volume subscription.

`workout_controller.dart` connects the engine to preferences and the platform
backends. Timing, cue policy and playback coordination are Dart. Native playback
uses `audioplayers`, with media-player completion events to play the finish sound
three times. Device playback can introduce small gaps between those hits.
The web backend uses decoded Web Audio buffers and a GainNode, scheduling five
minutes ahead and topping up on ticks and visibility changes. It rebases future
audio after context interruption.

The shared cue policy drops expired alarms and delivers the completion sequence
once. Successful cues gate the next alarm by planned time, so delivery jitter
cannot drop a three-second rest cue. Pause, Stop and a new plan cancel queued
sounds and reset that guard. Volume changes apply immediately; gain is the square
of the slider fraction, matching the original app. Preferences save after a
250 ms debounce; interval settings save on Start.

As in the Android original, there is no foreground service or notification in
this version. A suspended device, terminated process or discarded browser tab
cannot guarantee alarms. An active workout is not restored after process exit.

## Credits and licence

EasyTimer is licensed under [GPL-3.0](LICENSE).

The original timer behaviour, layout, translations and the unmodified
`hit.wav` and `threesecbeep.wav` assets come from Interval Timer, © 2023 Matthew
Nienow and contributors, under the MIT licence. Volume labels come from Jiří
Němec's MIT-licensed fork. The generic monospace typography is supplied by
bundled Droid Sans Mono, © 2007 Google Corporation, under the Apache License
2.0. The speaker paths are Google Material Design Icons under Apache-2.0.
Fonts are never fetched at runtime. Full attribution, pinned sources and
third-party licence texts are listed in [NOTICE](NOTICE).
