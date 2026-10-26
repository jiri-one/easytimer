#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$root"
output=$(mktemp -d "${TMPDIR:-/tmp}/easytimer-native.XXXXXX")
trap 'rm -rf -- "$output"' EXIT
compiler=${CXX:-c++}
flags=(-std=c++14 -g -O1 -Wall -Wextra -Werror -pthread)
if [[ ${SANITIZE:-0} == 1 ]]; then
  flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
read -r -a pulse_flags <<< "$(pkg-config --cflags libpulse)"
"$compiler" "${flags[@]}" "${pulse_flags[@]}" -fPIC -shared \
  app/test/native/linux/fake_pulse.cc -o "$output/libpulse.so.0"
"$compiler" "${flags[@]}" "${pulse_flags[@]}" -Iapp/linux/runner \
  app/linux/runner/native_audio.cc app/test/native/linux/native_audio_test.cc \
  -L"$output" -Wl,-rpath,"$output" -l:libpulse.so.0 -ldl -o "$output/native_audio_test"
LD_LIBRARY_PATH="$output${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$output/native_audio_test"

"$compiler" "${flags[@]}" "${pulse_flags[@]}" -Iapp/linux/runner \
  app/linux/runner/native_audio.cc app/test/native/linux/real_pulse_test.cc \
  -ldl -o "$output/real_pulse_test"
python3 app/test/native/linux/stalled_server.py "$output/real_pulse_test"
if [[ ${LIVE_PULSE:-0} == 1 ]]; then
  sink="easytimer_native_test_$$"
  module=$(pactl load-module module-null-sink sink_name="$sink")
  trap 'pactl unload-module "$module"; rm -rf -- "$output"' EXIT
  PULSE_SINK="$sink" "$output/real_pulse_test" live
fi
flutter_linux=${FLUTTER_LINUX_DIR:-$root/app/linux/flutter/ephemeral}
if [[ -f "$flutter_linux/libflutter_linux_gtk.so" ]]; then
  read -r -a gtk_flags <<< "$(pkg-config --cflags gtk+-3.0)"
  read -r -a gtk_libs <<< "$(pkg-config --libs gtk+-3.0)"
  "$compiler" "${flags[@]}" -Iapp/linux/runner -I"$flutter_linux" "${gtk_flags[@]}" \
    app/test/native/linux/native_protocol_test.cc -L"$flutter_linux" \
    -Wl,-rpath,"$flutter_linux" -lflutter_linux_gtk "${gtk_libs[@]}" -o "$output/native_protocol_test"
  G_DEBUG=fatal-warnings "$output/native_protocol_test"
  if [[ ${CHECK_RUNNER:-0} == 1 ]]; then
    "$compiler" "${flags[@]}" -Wno-unused-parameter "${pulse_flags[@]}" \
      -Iapp/linux -I"$flutter_linux" "${gtk_flags[@]}" \
      '-DAPPLICATION_ID="one.jiri.easytimer"' \
      app/linux/runner/main.cc app/linux/runner/my_application.cc \
      app/linux/runner/native_audio.cc app/linux/runner/platform_bridge.cc \
      app/linux/runner/screen_inhibitor.cc \
      app/linux/flutter/generated_plugin_registrant.cc \
      -L"$flutter_linux" -lflutter_linux_gtk "${gtk_libs[@]}" -ldl -o "$output/runner"
  fi
else
  printf '%s\n' 'SKIP MethodChannel value tests: set FLUTTER_LINUX_DIR to prepared Linux engine artifacts'
fi
app/test/native/linux/run_inhibit.sh
