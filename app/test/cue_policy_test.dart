import 'package:easytimer/cue_policy.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only successful planned cues stamp the exact 3000ms guard', () {
    final policy = CuePolicy();
    const first = SoundEvent(SoundKind.alarm, 0, 49);
    for (final now in [0, 10, 20, 49]) {
      expect(policy.allows(first, now), isTrue);
    }
    policy.started(first, 49);
    expect(policy.handled(first), isTrue);
    expect(policy.allows(first, 49), isFalse);
    expect(
      policy.allows(const SoundEvent(SoundKind.alarm, 2999, 3048), 2999),
      isFalse,
    );
    expect(
      policy.allows(const SoundEvent(SoundKind.alarm, 3000, 3049), 3000),
      isTrue,
    );
    policy.reset();
    expect(policy.allows(first, 49), isTrue);
  });

  for (final now in [100, 149, 150]) {
    test('alarm deadline at callback $now is inclusive', () {
      final policy = CuePolicy();
      const alarm = SoundEvent(SoundKind.alarm, 100, 149);
      expect(policy.expired(alarm, now), now > 149);
      expect(policy.allows(alarm, now), now <= 149);
    });
  }

  test('future reservations do not consume successful-start policy', () {
    final policy = CuePolicy();
    const cues = [
      SoundEvent(SoundKind.alarm, 0, 49),
      SoundEvent(SoundKind.alarm, 2999, 3048),
      SoundEvent(SoundKind.alarm, 3000, 3049),
    ];
    expect(policy.select(cues, 0).map((cue) => cue.atMs), [0, 3000]);
    expect(cues.any(policy.handled), isFalse);
    expect(policy.allows(cues[1], 2999), isTrue);
  });

  test('end identity persists indefinitely until the next cancelled plan', () {
    final policy = CuePolicy();
    const end = SoundEvent(SoundKind.end, 10000, null);
    expect(policy.allows(end, 1000000000000), isTrue);
    policy.started(end, 1000000000000);
    expect(policy.allows(end, 2000000000000), isFalse);
    expect(
      policy.allows(
        const SoundEvent(SoundKind.end, 20000, null),
        2000000000000,
      ),
      isFalse,
    );
    policy.reset();
    expect(policy.allows(end, 2000000000000), isTrue);
  });
}
