import 'package:easytimer/cue_policy.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('merge owns a sorted plan with one pending instance per ID', () {
    final policy = CuePolicy();
    const first = SoundEvent(SoundKind.alarm, 100, 149);
    const second = SoundEvent(SoundKind.alarm, 3100, 3149);
    const finish = SoundEvent(SoundKind.end, 3200, null);
    expect(policy.merge([second, first, first, finish]), isTrue);
    expect(policy.merge([first, second, finish]), isFalse);
    expect(policy.due(0), [first, second, finish]);
    expect(
      policy.merge(const [SoundEvent(SoundKind.end, 4000, null)]),
      isFalse,
    );
    expect(policy.due(0), [first, second, finish]);
  });

  test('only successful planned cues stamp the exact 3000ms guard', () {
    final policy = CuePolicy();
    const first = SoundEvent(SoundKind.alarm, 0, 49);
    policy.merge([first]);
    for (final now in [0, 10, 20, 49]) {
      expect(policy.due(now), [first]);
    }
    policy.started(first);
    expect(policy.handled(first), isTrue);
    expect(policy.merge([first]), isFalse);
    expect(policy.due(49), isEmpty);
    const early = SoundEvent(SoundKind.alarm, 2999, 3048);
    const exact = SoundEvent(SoundKind.alarm, 3000, 3049);
    policy.merge([early, exact]);
    expect(policy.due(2999), [exact]);
    policy.reset();
    expect(policy.due(0), isEmpty);
    policy.merge([early]);
    expect(policy.due(2999), [early]);
  });

  for (final now in [100, 149, 150]) {
    test('alarm deadline at callback $now is inclusive', () {
      final policy = CuePolicy();
      const alarm = SoundEvent(SoundKind.alarm, 100, 149);
      policy.merge([alarm]);
      expect(policy.expired(alarm, now), now > 149);
      expect(policy.due(now), now <= 149 ? [alarm] : isEmpty);
    });
  }

  test(
    'failed reservations do not permanently drop future guard conflicts',
    () {
      final policy = CuePolicy();
      const cues = [
        SoundEvent(SoundKind.alarm, 0, 49),
        SoundEvent(SoundKind.alarm, 2999, 3048),
        SoundEvent(SoundKind.alarm, 3000, 3049),
      ];
      policy.merge(cues);
      expect(policy.due(0), [cues[0], cues[2]]);
      policy.failed(cues[0]);
      expect(cues.any(policy.handled), isFalse);
      expect(policy.due(2999), [cues[1]]);
      expect(policy.due(3049), [cues[2]]);
    },
  );

  test('expired in-flight cue is retained until its start reply arrives', () {
    final policy = CuePolicy();
    const alarm = SoundEvent(SoundKind.alarm, 0, 49);
    const next = SoundEvent(SoundKind.alarm, 2999, 3048);
    policy.merge([alarm, next]);
    expect(policy.due(100, inFlight: alarm.id), [alarm]);
    expect(policy.merge([alarm]), isFalse);
    policy.started(alarm);
    expect(policy.due(2999), isEmpty);
    expect(policy.handled(alarm), isTrue);
  });

  test('expired cues are pruned without falsely marking success', () {
    final policy = CuePolicy();
    const alarm = SoundEvent(SoundKind.alarm, 0, 49);
    policy.merge([alarm]);
    expect(policy.due(50), isEmpty);
    expect(policy.handled(alarm), isFalse);
    expect(policy.merge([alarm]), isTrue);
    expect(policy.due(50), isEmpty);
  });

  test('failed finish is removed but can be explicitly rescheduled', () {
    final policy = CuePolicy();
    const finish = SoundEvent(SoundKind.end, 0, null);
    policy.merge([finish]);
    policy.failed(finish);
    expect(policy.due(10000), isEmpty);
    expect(policy.handled(finish), isFalse);
    expect(policy.merge([finish]), isTrue);
    expect(policy.due(10000), [finish]);
  });

  test('all successful identities persist indefinitely until reset', () {
    final policy = CuePolicy();
    const alarm = SoundEvent(SoundKind.alarm, 100, null);
    const end = SoundEvent(SoundKind.end, 10000, null);
    policy.merge([alarm, end]);
    policy.started(alarm);
    policy.started(end);
    expect(policy.due(1000000000000), isEmpty);
    expect(policy.merge([alarm, end]), isFalse);
    expect(
      policy.merge(const [SoundEvent(SoundKind.end, 20000, null)]),
      isFalse,
    );
    policy.reset();
    expect(policy.merge([alarm, end]), isTrue);
    expect(policy.due(2000000000000), [alarm, end]);
  });

  test('retry and cancellation rules are shared by sound kind', () {
    expect(SoundKind.alarm.retries, isTrue);
    expect(SoundKind.alarm.keepsOnCancel, isFalse);
    expect(SoundKind.end.retries, isFalse);
    expect(SoundKind.end.keepsOnCancel, isTrue);
  });
}
