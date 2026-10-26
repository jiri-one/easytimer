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
              );

  final ClockGetTime _read;

  @override
  int get nowMs {
    final time = calloc<Timespec>();
    try {
      // CLOCK_BOOTTIME includes suspend and matches Android elapsedRealtime.
      if (_read(7, time) != 0) {
        throw StateError('CLOCK_BOOTTIME is unavailable');
      }
      return time.ref.seconds * 1000 + time.ref.nanoseconds ~/ 1000000;
    } finally {
      calloc.free(time);
    }
  }
}

MonotonicClock createClock() =>
    Platform.isAndroid || Platform.isLinux ? BootClock() : StopwatchClock();
