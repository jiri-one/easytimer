import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:wakelock_plus/wakelock_plus.dart';

class ScreenWakeLock {
  Future<void> _change = Future.value();

  void setEnabled(bool enabled) {
    _change = _change
        .then((_) async {
          if (await WakelockPlus.enabled != enabled) {
            if (enabled && kIsWeb) {
              // A queued recovery may outlive the visible state while hiding.
              final state = WidgetsBinding.instance.lifecycleState;
              if (state != AppLifecycleState.resumed &&
                  state != AppLifecycleState.inactive) {
                return;
              }
            }
            await (enabled ? WakelockPlus.enable() : WakelockPlus.disable());
          }
        })
        .catchError((Object _) {});
  }
}
