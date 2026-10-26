# Packaging and releases

- `linux/` — desktop entry, AppStream metadata, SVG and rendered icons for Linux and Flatpak
- `screenshots/` — real app screenshots to add before store submission
- `flatpak/flatpak-flutter.yml` — input for [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter), which generates the offline Flathub manifest
- `flatpak/build.sh` — build and bundle the current local commit, without installing the app
- `fdroid/one.jiri.easytimer.yml` — the [fdroiddata](https://gitlab.com/fdroid/fdroiddata) recipe
- `../branding/` — SVG sources and the icon generator; PNG outputs are committed
- `../app/fastlane/` — English and Czech Android store text and icon

The app ID is `one.jiri.easytimer`, the executable and Dart package are `easytimer`,
and the display name is EasyTimer. The application code is GPL-3.0-only. The sounds
and translations reused from [Interval Timer](https://github.com/randombits-dev/interval-timer)
are MIT-licensed, copyright 2023 Matthew Nienow and contributors. AppStream therefore declares
`GPL-3.0-only AND MIT AND Apache-2.0`; its metadata is dedicated to CC0-1.0.
Droid Sans Mono and the speaker vectors are Apache-2.0.

Custom licence texts and attribution come from `app/assets/licenses/`. Flutter
includes this directory once in every artifact: APK `assets/flutter_assets/assets/licenses/`,
Linux `data/flutter_assets/assets/licenses/`, and web `assets/assets/licenses/`.
Tarballs retain these bundled files without another licence directory. Flutter
generates dependency licences, including `audioplayers` and `wakelock_plus`, in
`NOTICES` (web) or `NOTICES.Z` (native) at the asset-bundle root. No extra Flutter
licence copy is installed. Keep root `NOTICE` synchronized with the bundled
`NOTICE.txt`, and root `LICENSE` with `EasyTimer-GPL-3.0.txt`.

## Local checks

Use Flutter **3.47.7**. From the repository root:

```sh
desktop-file-validate packaging/linux/one.jiri.easytimer.desktop
appstreamcli validate --no-net packaging/linux/one.jiri.easytimer.metainfo.xml
cd app
flutter pub get --enforce-lockfile
flutter analyze
flutter test --concurrency=4 --no-pub
flutter test --concurrency=4 --no-pub --platform chrome --dart-define=WEB_PLUGIN_TESTS=true test/web_platform_test.dart test/web_wake_lock_test.dart
flutter test --concurrency=4 --no-pub --wasm --platform chrome --dart-define=WEB_PLUGIN_TESTS=true test/web_platform_test.dart test/web_wake_lock_test.dart
(
  socket_dir=$(mktemp -d "${TMPDIR:-/tmp}/easytimer-dbus.XXXXXX") || exit
  socket_dir=$(cd "$socket_dir" && pwd -P) || exit
  trap 'rm -rf "$socket_dir"' EXIT
  dbus-daemon --session --address="unix:path=$socket_dir/bus" \
    --fork --print-pid=3 3>"$socket_dir/pid" || exit
  trap 'kill "$(cat "$socket_dir/pid")"; rm -rf "$socket_dir"' EXIT
  DBUS_SESSION_BUS_ADDRESS="unix:path=$socket_dir/bus" \
  EASYTIMER_PRIVATE_DBUS="unix:path=$socket_dir/bus" \
  EASYTIMER_TEST_SOCKET_DIR="$socket_dir" \
    flutter test --concurrency=4 --no-pub test/wakelock_linux_test.dart
)
./tool/build_web.sh
flutter build linux --release
flutter build apk --release
```

The real Linux portal test reports a skip unless `EASYTIMER_PRIVATE_DBUS` exactly
matches `DBUS_SESSION_BUS_ADDRESS` and `EASYTIMER_TEST_SOCKET_DIR` declares the
existing test-owned socket directory. The directory and socket must use canonical
paths without symlinks; sockets under `/run/user/` are rejected. The private-bus
command above creates and cleans up its own directory under `${TMPDIR:-/tmp}`.

After changing the branding, run `./branding/generate.sh` from the repository
root and inspect the generated files. The generator needs `rsvg-convert` from
librsvg. It generates Android legacy, adaptive and monochrome launchers, web and
maskable icons, the favicon, the store
icon, and Linux PNGs from 16 to 512 pixels. The full-size rendered icon is
`packaging/linux/icons/hicolor/512x512/apps/one.jiri.easytimer.png`. PNG rendering
varies by librsvg version, so CI validates committed icon files without
regenerating them.

Native audio uses `audioplayers` without requesting audio focus. The finish WAV
is loaded with its PCM samples repeated three times and played as one BytesSource,
avoiding gaps between separately started hits. Linux stores each cue in a stable
file under the app's cache directory and reuses it across launches. Cache files
are published atomically and recreated after eviction. The Linux plugin checks
GStreamer core, app and audio pkg-config modules. Build dependencies on Debian/Ubuntu are
`libgstreamer1.0-dev` and `libgstreamer-plugins-base1.0-dev`, alongside Flutter's
standard GTK development tools. Runtime dependencies include GStreamer's base
and good plugins (`gstreamer1.0-plugins-base` and `gstreamer1.0-plugins-good`) for
WAV decoding and audio output. The Freedesktop Flatpak runtime supplies these;
`--socket=pulseaudio` permits host playback. The browser uses Web Audio with
bundled decoded WAVs and a GainNode.

Screen wake lock uses `wakelock_plus`. On Linux it calls
`org.freedesktop.portal.Inhibit` on `org.freedesktop.portal.Desktop`, so the host
needs a portal backend supporting idle inhibition. Flatpak permits portal APIs
by default, with no extra D-Bus talk permission. See
[Flatpak's D-Bus permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html#d-bus-access).
No network or host filesystem permission is granted. Test sound cues and screen
inhibition in the final sandbox before submission.

## CI and releases

`ci.yml` analyzes and tests Dart, builds web, Linux and a debug APK, and checks
desktop metadata and icons. The `app` job builds web once and uploads the Pages
artifact; deployment from `main` waits for both `tests` and `app`. Manual CI runs
on `main` can also deploy. Ordinary CI needs no Android signing secrets.

`flatpak.yml` runs on relevant pull requests (`packaging/flatpak/**`, `app/linux/**`,
or `**/pubspec.lock`), Mondays at 04:23 UTC, and release tags
through `release.yml`. It caches Flatpak Builder downloads and build state plus
the user runtime installation at `~/.local/share/flatpak`.
Actions are pinned by SHA. The shared `.github/actions/flutter` action defines
the Flutter version and setup-action pin once and enforces the committed pub
lockfile. Flutter action jobs cache the SDK and pub packages; Android jobs cache
Gradle. Linux ARM releases cache the Flutter SDK source checkout.

All paths below are relative to the repository root:

1. Set the release version in `app/pubspec.yaml`, for example `1.0.0+1`. Increase
   the number after `+` on every release and commit the matching `app/pubspec.lock`.
2. Add the release and its actual release date to
   `packaging/linux/one.jiri.easytimer.metainfo.xml`, and add
   `app/fastlane/metadata/android/{en-US,cs-CZ}/changelogs/<build number>.txt`.
   The initial metadata is for `1.0.0+1`; update its date before publishing.
3. Confirm the Android secrets below are present, and run the local checks.
4. Commit, tag and push the approved source, for example:

   ```sh
   git tag v1.0.0
   git push origin main v1.0.0
   ```

5. `release.yml` runs on `v*` tags and publishes a GitHub release only after all
   builds succeed. It includes Linux x86_64 and aarch64 tarballs, an x86_64 Flatpak
   bundle, a signed universal Android APK plus arm64-v8a, armeabi-v7a and x86_64
   APKs, a web zip, and `SHA256SUMS`. Both Linux architectures are required.
6. Update and submit the Flathub manifest separately. F-Droid discovers matching
   version tags after its initial submission is accepted.

The tarballs contain the relocatable Flutter bundle, desktop entry, SVG icon,
AppStream metadata and licences. Extract a tarball and run `./easytimer` inside
its directory. For desktop integration, keep that directory in a stable location,
put an absolute path to its `easytimer` executable in the desktop file's `Exec=`,
and install the entry and icon under `~/.local/share/applications/` and
`~/.local/share/icons/hicolor/scalable/apps/`. The tarball depends on compatible
GTK and GStreamer libraries and the base and good plugins; Flatpak supplies its
own runtime.

Check a downloaded release with `sha256sum -c SHA256SUMS`. Install the Flatpak
bundle with `flatpak install --user ./easytimer-<version>-linux-x86_64.flatpak`.
Extract the web zip at the root of a static HTTPS site.

## Android signing

Reuse a release key that Jiří controls and keep it backed up. No key is included
or generated by the packaging scripts. Add these repository Actions secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the existing release keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Existing signing key alias |
| `ANDROID_KEY_PASSWORD` | Signing key password |

When supplied, the tag workflow decodes the keystore to `app/android/release.jks`
on the runner and passes the passwords and alias through environment variables. This preserves
backslashes, leading spaces and Unicode that Java properties files would otherwise
interpret. It removes the keystore after the build. Gradle validates the complete
signing configuration and rejects tag builds with missing secrets or a missing
keystore. These secrets are never used by PR builds.

For local signing, use the ignored `app/android/key.properties`:

```properties
storeFile=/absolute/path/to/existing-release.jks
storePassword=your-store-password
keyAlias=your-existing-alias
keyPassword=your-key-password
```

Relative `storeFile` paths are resolved from `app/android/`. The equivalent
environment variables are `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`; a nonblank property takes
precedence over its environment variable. Partial settings and a nonexistent
keystore fail. Without any settings, local non-tag release builds warn and use
the existing Android debug key. `GITHUB_REF_TYPE=tag` requires the release key;
set it when building a tagged release locally.

F-Droid removes the signing assignment and builds an unsigned universal APK, then
signs it with its own key. Its version code equals the pubspec build number, so
`changelogs/1.txt` applies to the first build. GitHub ABI-specific APKs use Flutter's
ABI version-code offsets. F-Droid and GitHub installations have different signing
keys and cannot update each other. Google's dependency-info blobs are disabled in
both APK and AAB output. Audit any new dependency for a free licence and proprietary
SDKs before submitting to F-Droid.

## GitHub Pages and DNS

The web script uses `flutter build web --release --base-href /` with JavaScript
and locally bundled CanvasKit and Droid Sans Mono. Native and web builds register
that font only as Flutter's default Roboto family. JavaScript
is the conservative production build; `app/tool/build_web.sh --wasm` keeps the
Skwasm renderer and Web Audio backend. A Wasm build also has a JavaScript fallback,
but requires Wasm-compatible dependencies; multithreaded Wasm rendering
requires cross-origin-isolation headers. See
[Flutter's Wasm documentation](https://docs.flutter.dev/platform-integration/web/wasm).
The manifest uses EasyTimer, standalone display and both regular and maskable icons.
An offline Android/Linux app does not by itself guarantee offline web availability;
check the web caching behaviour separately before advertising it.

Jiří must configure the following, in this order:

1. In **GitHub account Settings → Pages → Add a domain**, verify `jiri.one` if it is
   not already verified. In Cloudflare, add a **TXT** record named
   `_github-pages-challenge-jiri-one` in the `jiri.one` zone, with the exact token
   GitHub supplies. Its full name is `_github-pages-challenge-jiri-one.jiri.one`.
   Return to GitHub and select **Verify**; retain the TXT record. Verifying the
   parent domain also protects its immediate subdomains, including `easytimer`.
   See [GitHub's domain verification instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/verifying-your-custom-domain-for-github-pages).
2. In repository **Settings → Pages → Build and deployment → Source**, select
   **GitHub Actions**. Under **Custom domain**, save `easytimer.jiri.one`.
   Allow the `github-pages` environment to deploy from `main` and ensure the Actions
   token can deploy Pages; the workflow requests `pages: write` and `id-token: write`.
3. In Cloudflare DNS for `jiri.one`, add **CNAME**, name **`easytimer`**, target
   **`jiri-one.github.io`**, proxy status **DNS only** (grey cloud), TTL Auto.
   The target is the account domain, without a repository path.
4. After DNS and certificate provisioning finish, enable **Enforce HTTPS** in
   repository Pages settings. Push an approved commit to `main` or run CI manually
   from `main`, then check `https://easytimer.jiri.one`.

With an Actions publishing source, GitHub ignores a `CNAME` file in the artifact
and does not require one. The repository Pages **Custom domain** setting is the
configuration that matters, so the build does not create a `CNAME` file. See
[GitHub's custom domain instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site).
The base path `/` assumes that custom domain; the default repository-path URL is
not the deployment target.

## Flatpak and Flathub

The manifest uses Freedesktop **26.08**, **llvm22** and Flutter
**3.47.7**. `flatpak-flutter` prefetches and pins the Flutter SDK, pub packages and
other sources so that the actual build runs without network access. The app has
Wayland, fallback X11, IPC, DRI and PulseAudio access; it has no network access.
Custom licences remain in `/app/easytimer/data/flutter_assets/assets/licenses/`.
`/app/share/licenses/one.jiri.easytimer/` links to that directory. Automatic
licence collection is disabled for this module so each custom notice has one
physical copy. Flutter's generated dependency notices
remain at `/app/easytimer/data/flutter_assets/NOTICES.Z`.

For the same local-commit build used by CI, first have the Freedesktop Platform,
Sdk and llvm22 extension for 26.08, plus either `flatpak-builder` or the
`org.flatpak.Builder` app. Prepare the generator in a local Python environment:

```sh
git clone https://github.com/TheAppgineer/flatpak-flutter.git /path/to/flatpak-flutter
git -C /path/to/flatpak-flutter checkout e59a96fcb0fcf48fcd46e8134cae64c26fdc3290
python3 -m venv /path/to/flatpak-flutter/.venv
/path/to/flatpak-flutter/.venv/bin/pip install -r /path/to/flatpak-flutter/requirements.txt
export PATH="/path/to/flatpak-flutter/.venv/bin:$PATH"
FLATPAK_FLUTTER=/path/to/flatpak-flutter/flatpak-flutter.py ./packaging/flatpak/build.sh
```

Commit all intended source changes first: the helper builds **HEAD**, not the
working directory. Output is `app/build/flatpak/easytimer.flatpak`; the generated
local manifest, dependency manifests and build repository are under the same
ignored directory. CI builds it on relevant PRs, weekly and on release tags.
The local manifest points to a local Git checkout and is not the Flathub submission.

Before a Flathub release:

1. Add real screenshots and their tagged URLs to the AppStream metadata. Update
   the source in `packaging/flatpak/flatpak-flutter.yml` to the published release
   tag, replacing `branch: main` with e.g. `tag: v1.0.0`.
2. Generate and validate the release manifest with the pinned generator:

   ```sh
   cd packaging/flatpak
   /path/to/flatpak-flutter/.venv/bin/python /path/to/flatpak-flutter/flatpak-flutter.py flatpak-flutter.yml
   flatpak run --command=flathub-build org.flatpak.Builder --install one.jiri.easytimer.yml
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest one.jiri.easytimer.yml
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo repo
   flatpak run one.jiri.easytimer
   ```

3. Test the finished app, including GStreamer sound cues and portal inhibition. Copy
   `one.jiri.easytimer.yml` and `generated/` into a fork of `flathub/flathub` on a
   branch based on **`new-pr`**, then submit a PR against **`new-pr`** titled
   **Add one.jiri.easytimer**. Follow the current
   [Flathub submission instructions](https://docs.flathub.org/docs/for-app-authors/submission).
   After acceptance, keep GitHub 2FA enabled and accept the repository invitation
   within one week. Future updates go to that app repository.
4. In the Flathub Developer Portal, select the app and Verification. Serve its
   exact verification token over HTTPS at
   `https://jiri.one/.well-known/org.flathub.VerifiedApps.txt`. Preserve any existing
   domain-verification tokens and add EasyTimer's token on its own line. The domain is
   `jiri.one`, derived from the app ID. Flathub also supports a TXT record at
   `_flathub.jiri.one`; follow the token instructions in the portal. See
   [Flathub verification](https://docs.flathub.org/docs/for-app-authors/verification).

Regenerate the offline manifest whenever the release tag, Flutter pin, lockfile
or native dependency sources change. Keep temporary generated manifests, build
logs and repositories out of the source repository.

## F-Droid submission

After publishing the first version tag, add real screenshots under
`app/fastlane/metadata/android/{en-US,cs-CZ}/images/phoneScreenshots/`. The initial
English and Czech descriptions, icon and `changelogs/1.txt` are already present.
Confirm the release matches `CurrentVersion`, `CurrentVersionCode` and the first
build in the recipe. The recipe uses Flutter **3.47.7**, NDK **r28c**, the committed
lockfile and an unsigned universal APK; it contains no proprietary dependencies.

Fork `fdroid/fdroiddata` on GitLab, copy
`packaging/fdroid/one.jiri.easytimer.yml` to `metadata/one.jiri.easytimer.yml`, run
`fdroid lint one.jiri.easytimer` and a test build in the F-Droid build environment,
then submit a merge request. F-Droid imports the metadata from `app/fastlane/` and
discovers later `v<version>` tags using the pubspec version and build number. See
[F-Droid's metadata reference](https://f-droid.org/en/docs/Build_Metadata_Reference/).
