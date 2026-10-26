# EasyTimer

A simple interval timer for Android, Linux and the browser. EasyTimer is a Flutter
rewrite of [Interval Timer](https://github.com/randombits-dev/interval-timer), with
large controls and high-contrast light/dark themes suited to e-ink screens.
Text is black on white or white on black. Green ACTIVE and red REST labels
have at least 7:1 contrast; the coloured control-button fills are preserved.
Text and controls scale with the window for reading from a distance. Wide timer
windows put the countdown beside a vertical control column; fullscreen and
maximised windows use the available space without a fixed size cap.

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
flutter pub get --enforce-lockfile
flutter analyze
flutter test --concurrency=4 --no-pub
flutter test --concurrency=4 --no-pub --platform chrome --dart-define=WEB_PLUGIN_TESTS=true test/web_platform_test.dart test/web_wake_lock_test.dart
flutter test --concurrency=4 --no-pub --wasm --platform chrome --dart-define=WEB_PLUGIN_TESTS=true test/web_platform_test.dart test/web_wake_lock_test.dart
./tool/build_web.sh
./tool/build_web.sh --wasm
flutter build linux --release
flutter build apk --release
```

Run the isolated Linux portal test using the private-bus setup in the
[packaging instructions](packaging/README.md).

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
pixels at DPR 1.5, 1.875 and 2.5, 420×760 and 640×400 desktop windows, a
1440×900 browser, and 1920×1080 / 3200×1800 fullscreen layouts at DPR 1 and 2.
Long French labels and a three-digit countdown are covered too.
Run the UI, golden and bundled font/licence checks together with
`flutter test --concurrency=4 --no-pub test/widget_test.dart test/golden_test.dart test/font_manifest_test.dart`.
Generated localization bindings are tracked. Regenerate them
with `flutter gen-l10n` after editing the ARB files; CI checks the result.
After an intentional visual change, regenerate goldens with:

```sh
flutter test --concurrency=4 test/golden_test.dart --update-goldens
```

## Implementation

`app/lib/timer_engine.dart` derives the current phase, set, display and sound
boundaries from a monotonic clock. Android and Linux read `CLOCK_BOOTTIME`
through FFI, including suspend; the web uses `performance.now()`. Late callbacks
do not extend a phase; cues already stale when noticed are skipped. Timer text updates on displayed
second or state changes, with a separate volume subscription.

`workout_controller.dart` connects the engine to preferences and the platform
backends. Timing, cue policy and playback coordination are Dart. The finish WAV's
PCM samples are tripled at load time so the three hits play as one continuous
buffer. Native playback preloads one `audioplayers` player per cue kind and rewinds
it after completion or Stop, so a ready cue only needs resume. A cue waits for
any rewind still in progress. Android silently primes each player once during
initialization, then pauses and rewinds it before restoring the current volume.
The media context requests no audio focus, including during priming. Device mixer
latency remains outside the app's control.
Linux reuses stable `audio/alarm.wav` and `audio/end.wav` files in the application's
cache directory. Files are published atomically and recreated after eviction.
The original bundled WAV files are unchanged. The web backend decodes the same buffers into
Web Audio and uses a GainNode, scheduling five minutes ahead and topping up on
ticks and visibility changes. It rebases future
audio after context interruption.

The shared cue policy drops expired alarms and delivers the completion sequence
once. Successful cues gate the next alarm by planned time, so delivery jitter
cannot drop a three-second rest cue. Pause, Stop and a new plan cancel queued
sounds and reset that guard. Volume changes apply immediately; gain is the square
of the slider fraction, matching the original app. Volume saves after a 250 ms
debounce; interval settings save serialized snapshots on each edit and on Start.
Linux validates its preference file before loading it. Invalid data is preserved
untouched in a `.corrupt` backup, and valid entries are kept in the repaired store.
Unavailable storage is retried on later saves. Only the `volumePercent` preference is read; older fractional `volume` values are not
migrated.

Native alarm eligibility is checked when a cue becomes due. Once accepted,
a cue plays even if preparation or playback starts late; plugin start latency
is not bounded. A start that returns after cancellation is stopped immediately,
but a short stale sound can still occur. On Linux,
`audioplayers` can wait indefinitely for a GStreamer state change. A stalled
pipeline can block Stop and the window; Dart cannot interrupt that native wait.

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
The web wake-lock plugin includes NoSleep.js, © Rich Tibbett, under MIT.
Fonts are never fetched at runtime. Full attribution, pinned sources and
third-party licence texts are listed in [NOTICE](NOTICE).
