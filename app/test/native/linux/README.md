# Linux native probes

Run from the repository root:

```sh
app/test/native/linux/run.sh
SANITIZE=1 CXX=clang++ app/test/native/linux/run.sh
CHECK_RUNNER=1 LIVE_PULSE=1 app/test/native/linux/run.sh
```

The script compiles the production `NativeAudio` implementation with a fake
`libpulse.so.0`. Faults delay connection, stream readiness and first writable data,
or leave connection, writes and drain permanently pending. Tests cover absolute
BOOTTIME deadlines, the 3000 ms guard between successfully played planned cues,
failed-start retries, concurrent duplicate IDs, generation rejection, alarm-only cancellation,
subsequent playback, replies, teardown, bundled WAV decoding and three end hits.
The required `plannedAtMs` is an absolute BOOTTIME timestamp. It is recorded for
the guard only after a successful enqueue; `startedAtMs` receipts still report
the actual enqueue time. This revised contract supersedes the earlier guard
between actual starts: 50 ms scheduling jitter must not suppress adjacent cues
planned exactly three seconds apart. Failed starts do not consume the guard.
`beginWorkout` advances event generations and cancels alarms and old pending
events while retaining an end sound that has already started. A subsequent cue
can replace it, and full Stop still silences it.
Cancellation and disposal at each injected stage must finish within 50 ms.
Unresponsive stages without cancellation must time out within 1400 ms.

A separate executable loads the real system libpulse against a temporary Unix
socket that accepts connections but never answers. It verifies deadline expiry,
timeout, Stop, another request and disposal without a functioning sound server.
The default suite needs C++14, libpulse development headers, pkg-config and
Python 3. It uses temporary build directories and installs nothing.

When prepared Flutter Linux engine artifacts exist, the script also checks the
production MethodChannel argument parsers and result maps with real `FlValue`
objects, with GLib warnings fatal. Set `FLUTTER_LINUX_DIR` to use another prepared
engine directory. This requires GTK development files. `CHECK_RUNNER=1` additionally
compiles and links the Linux runner directly; it does not invoke Flutter or launch
a GUI.

`LIVE_PULSE=1` requires a working local PulseAudio-compatible server and `pactl`.
It creates and removes a uniquely named null sink, routes only the probe to that
sink, and verifies both bundled cues with zero gain. It leaves default devices,
volumes and application preferences untouched. It checks enqueue/stop/dispose
behavior, not physical speaker latency, suspend/resume, Bluetooth or OEM audio
hardware. The 50 ms fault tests measure cancellation of native work; they do not
certify physical output latency on every device.

The backend dynamically loads `libpulse.so.0`, uses nonblocking mainloop
iterations, requests a 40 ms buffer, and limits connection, stalled writes and
drain to 1000 ms each. Its worker is joined on disposal. No simple-API drain or
permanently detached worker is used.
