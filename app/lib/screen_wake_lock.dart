import 'package:wakelock_plus/wakelock_plus.dart';

class ScreenWakeLock {
  Future<void> _change = Future.value();

  void setEnabled(bool enabled) {
    _change = _change
        .then((_) async {
          if (await WakelockPlus.enabled != enabled) {
            await WakelockPlus.toggle(enable: enabled);
          }
        })
        .catchError((Object _) {});
  }
}
