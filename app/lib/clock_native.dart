import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'clock_base.dart';

final class Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

typedef ClockGetTime = int Function(int, Pointer<Timespec>);
typedef _NativeClockGetTime = Int32 Function(Int32, Pointer<Timespec>);

class BootClock implements MonotonicClock {
  BootClock({ClockGetTime? read})
    : _read =
          read ??
          DynamicLibrary.process()
              .lookupFunction<_NativeClockGetTime, ClockGetTime>(
                'clock_gettime',
                isLeaf: true,
              );

  final ClockGetTime _read;
  static final _time = calloc<Timespec>();

  @override
  int get nowMs {
    // Synchronous reads share one buffer for the isolate's lifetime.
    if (_read(7, _time) != 0) {
      throw StateError('CLOCK_BOOTTIME is unavailable');
    }
    return _time.ref.seconds * 1000 + _time.ref.nanoseconds ~/ 1000000;
  }
}

MonotonicClock createClock() =>
    Platform.isAndroid || Platform.isLinux ? BootClock() : StopwatchClock();
