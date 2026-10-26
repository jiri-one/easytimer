@TestOn('vm')
library;

import 'dart:ffi';

import 'package:easytimer/clock.dart';
import 'package:easytimer/clock_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native default includes suspend and uses the host timespec ABI', () {
    expect(createWorkoutClock(), isA<BootClock>());
    expect(sizeOf<Timespec>(), sizeOf<IntPtr>() * 2);
    final clock = BootClock();
    final now = clock.nowMs;
    expect(now, greaterThan(0));
    expect(clock.nowMs, greaterThanOrEqualTo(now));
  });

  test(
    'CLOCK_BOOTTIME is read synchronously without an elapsed-time anchor',
    () {
      var seconds = 123;
      final clock = BootClock(
        read: (id, result) {
          expect(id, 7);
          result.ref
            ..seconds = seconds
            ..nanoseconds = 456999999;
          return 0;
        },
      );
      expect(clock.nowMs, 123456);
      seconds += 3600;
      expect(clock.nowMs, 3723456);
    },
  );

  test('clock failures are explicit instead of silently excluding suspend', () {
    expect(() => BootClock(read: (_, _) => -1).nowMs, throwsStateError);
  });
}
