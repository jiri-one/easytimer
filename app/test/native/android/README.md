# Android native playback probes

From the repository root:

```sh
python3 app/test/native/android/run.py
```

The runner compiles the production `MainActivity.kt` and `PlaybackPolicy.kt` with
small JVM Android/Flutter stubs, runs 28 behavioral probes, and then compiles the
same production sources against the installed Android API and cached Flutter
embedding. Both compilations target JVM 17 with warnings treated as errors.

The latest user contract deliberately supersedes the earlier actual-time guard:
both `playAlarm` and `playEnd` require an integer `plannedAtMs` in the absolute
BOOTTIME-compatible clock domain alongside `eventId`, `generation`,
`alarmGeneration` and `deadlineMs`. The alarm guard compares planned cue times,
accepts a gap of at least 3000 ms, and records the planned time only after
`SoundPool.play` succeeds. Receipts still report the actual successful start from
`SystemClock.elapsedRealtime`. Alarm deadlines are checked on receipt and again
before playback; ends ignore deadlines. Cancellation and new workouts preserve
the last successful planned alarm time.

`beginWorkout` accepts `generation` and `alarmGeneration`, advances the successful
event ledger's generation and invalidates pending alarms and ends. It stops an
active alarm while preserving an already playing end sound. The next successful
alarm can replace that sound through `SoundPool`'s single stream; full `stop`
still silences it. Stale workout controls do nothing.

Probes cover malformed or missing planned times, planned gaps with 50 ms actual
jitter, actual receipts, failed-play retries, duplicate requests, receive/start
deadlines, cancellation races and generations, workout transitions, end
preservation, initialization/recreation, loading timeouts, gain, media attributes,
volume keys, orientation and disposal.

Prerequisites are Python 3, Java 17 or newer, an Android SDK, and the Kotlin
compiler with its dependencies and Flutter/AndroidX jars in the Gradle cache.
Run this after an Android build has populated the cache. Debug, release and
profile Flutter embeddings are accepted. Nothing is downloaded or installed,
and the runner does not invoke Gradle or Flutter. `GRADLE_USER_HOME`,
`KOTLIN_VERSION`, `JAVA`, `ANDROID_JAR`, `ANDROID_SDK_ROOT`/`ANDROID_HOME` and
`FLUTTER_EMBEDDING_JAR` can select existing local dependencies.

Compiler commands, results and jars are saved in a printed temporary directory.
These tests execute production request handling with controlled clocks and
SoundPool results; they do not measure device SoundPool latency, audio focus
interactions on an OEM build, Bluetooth output or real deep sleep.
