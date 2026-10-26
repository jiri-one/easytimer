# EasyTimer

A simple interval timer for Android, Linux and the browser. EasyTimer is a Flutter
rewrite of [Interval Timer](https://github.com/randombits-dev/interval-timer), with
large controls, system light/dark colours and an interface suited to e-ink screens.

Set **Active**, **Rest** and **Sets**, then press Start. Preparation lasts five
seconds. An empty or zero set count repeats indefinitely. The last settings and
volume are saved locally. English, Czech, Catalan, Spanish and French follow the
system language, with English as the fallback.

Space starts, pauses or resumes; Escape stops; Up/Down change the timer volume by
5%. Android's volume keys always control media volume. The timer does not request
audio focus, so music and podcasts can keep playing.

Pausing preparation restarts its five seconds on resume. Pausing an active set
preserves its remaining time. Resuming from rest skips the rest of that break and
prepares the next set. The screen stays awake while the timer is shown, including
while paused, where the platform allows it.

## Build and test

Use Flutter 3.47.7 / Dart 3.13.5, an Android SDK for APK builds, and the standard
Flutter Linux build dependencies for desktop builds. From `app/`:

```sh
flutter pub get
flutter analyze
flutter test
flutter build web --release
flutter build web --release --wasm
flutter build linux --release
flutter build apk --debug
```

The web output is `app/build/web/`; serve it over HTTPS (localhost also works for
development). Screen Wake Lock requires a secure origin and may be denied by the
browser. WASM works without cross-origin isolation using its single-threaded
renderer, including on GitHub Pages.

Linux audio needs `libpulse-simple.so.0` and a PulseAudio-compatible server, such
as PipeWire's PulseAudio service. A Flatpak needs `--socket=pulseaudio` and that
library in its runtime. Audio is decoded locally; no services, proprietary audio
SDKs or Play services are used.

The committed golden tests load the bundled fonts and cover 824×1648 physical
pixels at DPR 1.5, 1.875 and 2.5, a 420×760 desktop window, and a 1440×900 browser.
After an intentional visual change, regenerate them with:

```sh
flutter test test/golden_test.dart --update-goldens
```

## Implementation

`app/lib/timer_engine.dart` derives the current phase, set, display and sound
boundaries from a monotonic clock. Late callbacks do not extend a phase. The UI
only updates when its displayed second or state changes.

`workout_controller.dart` connects that engine to persistence and the platform
bridge. Native sounds use one-shot timers. Android uses SoundPool with media /
sonification attributes and no audio focus. Linux streams PCM through a small
PulseAudio worker with live gain. The web backend uses decoded Web Audio buffers
and a GainNode, scheduling five minutes ahead and topping up on ticks and
visibility changes. Pause and Stop cancel scheduled sounds. Gain is the square of
the slider fraction, matching the original app.

As in the Android original, there is no foreground service or notification in
this version. A suspended device, terminated process or discarded browser tab
cannot guarantee alarms. An active workout is not restored after process exit.

## Credits and licence

EasyTimer is licensed under [GPL-3.0](LICENSE).

The original timer behaviour, layout, translations and the unmodified
`hit.wav` and `threesecbeep.wav` assets come from Interval Timer, © 2023 Matthew
Nienow, under the MIT licence. The generic monospace typography is supplied by
bundled Droid Sans Mono, © 2007 Google Corporation, under the Apache License
2.0. Fonts are never fetched at runtime. Full attribution, pinned sources and
third-party licence texts are listed in [NOTICE](NOTICE).
