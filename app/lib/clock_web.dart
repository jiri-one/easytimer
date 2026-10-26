import 'package:web/web.dart' as web;

import 'clock_base.dart';

class BrowserClock implements MonotonicClock {
  @override
  int get nowMs => web.window.performance.now().floor();
}

MonotonicClock createClock() => BrowserClock();
