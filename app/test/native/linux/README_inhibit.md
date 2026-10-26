# Linux screen inhibition probes

From the repository root:

```sh
app/test/native/linux/run_inhibit.sh
SANITIZE=1 CXX=clang++ app/test/native/linux/run_inhibit.sh
```

The script builds the production `ScreenInhibitor` with C++14 and warnings as
errors. It requires GIO development headers, pkg-config and dbus-run-session;
it installs nothing and needs no GUI. Every test process runs inside a private
`dbus-run-session` whose configuration contains no service activation directories.
The executable refuses to run without `EASYTIMER_INHIBIT_PRIVATE_BUS=1`, which
the script sets only inside that session. No test contacts the user's bus or
changes desktop settings. The stalled-connection case uses a private Unix socket
inside the same test session. Temporary files are removed on exit.

The fake ScreenSaver is a real GDBus service at
`org.freedesktop.ScreenSaver`, `/org/freedesktop/ScreenSaver`. Tests exercise the
production client against that service, including delayed/out-of-order replies,
errors, malformed replies, timeouts, service replacement, cancellation, rapid
toggles, late cleanup after disposal, and zero-valued D-Bus cookies. GTK callbacks
and the Flatpak detector are injectable, so these tests need no GTK window.
Additional processes test the default detector with empty and nonempty
`FLATPAK_ID`, missing/empty bus addresses, connection failures, and stalled
authentication. Inhibitors and client connections must be cleaned up; control
and destructor calls must return within 50 ms in these probes.

## Integration

Add `screen_inhibitor.cc` to the runner sources and link the existing GTK/GIO
dependencies. Construct `ScreenInhibitor` with a callback returning
`gtk_application_inhibit(application, window, GTK_APPLICATION_INHIBIT_IDLE,
"Timer is running")` and a callback calling
`gtk_application_uninhibit(application, cookie)`. Optional trailing constructor
arguments are application name (default `EasyTimer`), reason (default
`Timer is running`), and a Flatpak detector. Keep the callbacks' GTK captures
valid until disposal.

Call `SetEnabled(bool)` on the GTK thread. False releases inhibition and allows
a later enable. `Dispose()` is terminal and idempotent; the destructor calls it.
Construction, calls and destruction must use the same main-loop thread, and
its captured context must keep running for asynchronous cleanup. Repeated true
calls do not duplicate a pending or held inhibit. After an attempt fails, a new
true call retries GTK first. There is no automatic retry loop.

GTK is always tried first. If it returns zero, the fallback opens a dedicated
asynchronous GDBus connection using `DBUS_SESSION_BUS_ADDRESS`. If that variable
is absent or empty, the fallback is unavailable: it does not discover an address,
autolaunch a bus, or call a synchronous D-Bus API. The fallback is also disabled
when `FLATPAK_ID` is present (even empty) or `/.flatpak-info` exists. GTK remains
available in both cases.

Connection setup, Inhibit and UnInhibit each have a 1000 ms bound while the main
loop runs. Disabling or disposing during Inhibit preserves its pending reply
so a late cookie can be explicitly released. Retired attempts cannot alter a
new enable. Release targets the issuing service's unique bus name, avoiding
cookie collisions after service replacement. If an error or timeout hides a
cookie or prevents UnInhibit, the private connection closes; cleanup then relies
on the screensaver dropping inhibitors when their caller disconnects. This is
best effort against an unavailable or nonconforming desktop service.
