#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$root"
output=$(mktemp -d /tmp/easytimer-inhibit.XXXXXX)
trap 'rm -rf -- "$output"' EXIT
mkdir -m 700 "$output/runtime"
compiler=${CXX:-c++}
flags=(-std=c++14 -g -O1 -Wall -Wextra -Werror -pthread)
if [[ ${SANITIZE:-0} == 1 ]]; then
  flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
read -r -a gio_flags <<< "$(pkg-config --cflags gio-2.0)"
read -r -a gio_libs <<< "$(pkg-config --libs gio-2.0)"
"$compiler" "${flags[@]}" "${gio_flags[@]}" -Iapp/linux/runner \
  app/linux/runner/screen_inhibitor.cc \
  app/test/native/linux/screen_inhibitor_test.cc \
  "${gio_libs[@]}" -o "$output/screen_inhibitor_test"

# No service directories: an absent mock must not activate desktop services.
cat > "$output/bus.conf" <<'XML'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML

run_private() {
  dbus-run-session --config-file="$output/bus.conf" -- env \
    -u FLATPAK_ID -u DISPLAY -u WAYLAND_DISPLAY \
    -u DBUS_STARTER_ADDRESS -u DBUS_STARTER_BUS_TYPE \
    G_DEBUG=fatal-warnings XDG_RUNTIME_DIR="$output/runtime" \
    EASYTIMER_INHIBIT_PRIVATE_BUS=1 EASYTIMER_INHIBIT_TEST_DIR="$output" \
    "$@"
}

# Isolation must hold even if a future regression bypasses the refusal guard.
if run_private env -u EASYTIMER_INHIBIT_PRIVATE_BUS \
  "$output/screen_inhibitor_test" > "$output/refusal.log" 2>&1; then
  printf '%s\n' 'FAIL test binary accepted execution without the private-bus marker' >&2
  exit 1
else
  status=$?
  if [[ $status != 2 ]]; then
    cat "$output/refusal.log" >&2
    exit "$status"
  fi
fi
printf '%s\n' 'PASS test binary refuses execution without the private-bus marker'

run_private "$output/screen_inhibitor_test"
run_private env FLATPAK_ID= "$output/screen_inhibitor_test" --flatpak
run_private env FLATPAK_ID=one.jiri.easytimer \
  "$output/screen_inhibitor_test" --flatpak
run_private env -u DBUS_SESSION_BUS_ADDRESS \
  "$output/screen_inhibitor_test" --missing-address
run_private env DBUS_SESSION_BUS_ADDRESS= \
  "$output/screen_inhibitor_test" --missing-address
run_private env DBUS_SESSION_BUS_ADDRESS=invalid-address \
  "$output/screen_inhibitor_test" --connection-error
run_private "$output/screen_inhibitor_test" --stalled-connection
