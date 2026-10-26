import 'dart:typed_data';

import 'package:easytimer/audio.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sound assets include the full Flutter asset path', () {
    expect(SoundKind.alarm.asset, 'assets/audio/threesecbeep.wav');
    expect(SoundKind.end.asset, 'assets/audio/hit.wav');
  });

  test('gain uses the same squared curve at every volume', () {
    expect([0, 25, 50, 75, 100].map(gainOf), [0, 0.0625, 0.25, 0.5625, 1]);
  });

  test('alarm bytes and PCM header remain exact', () async {
    final original = await rootBundle.load(SoundKind.alarm.asset);
    final loaded = await loadSound(SoundKind.alarm);
    expect(loaded, original.buffer.asUint8List());
    final header = ByteData.sublistView(loaded);
    expect(loaded.length, 49966);
    expect(header.getUint32(4, Endian.little), loaded.length - 8);
    expect(header.getUint16(20, Endian.little), 1);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 7119);
    expect(header.getUint32(28, Endian.little), 14238);
    expect(header.getUint16(32, Endian.little), 2);
    expect(header.getUint16(34, Endian.little), 16);
    expect(header.getUint32(40, Endian.little), 49922);
  });

  test(
    'finish is one WAV with exactly three contiguous original payloads',
    () async {
      final asset = await rootBundle.load(SoundKind.end.asset);
      final original = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final originalHeader = ByteData.sublistView(original);
      final loaded = await loadSound(SoundKind.end);
      final header = ByteData.sublistView(loaded);
      const dataSize = 207364;
      expect(original.length, 207408);
      expect(originalHeader.getUint32(40, Endian.little), dataSize);
      expect(loaded.length, 44 + dataSize * 3);
      expect(header.getUint32(4, Endian.little), loaded.length - 8);
      expect(header.getUint32(40, Endian.little), dataSize * 3);
      expect(header.getUint16(20, Endian.little), 1);
      expect(header.getUint16(22, Endian.little), 2);
      expect(header.getUint32(24, Endian.little), 44100);
      expect(header.getUint32(28, Endian.little), 176400);
      expect(header.getUint16(32, Endian.little), 4);
      expect(header.getUint16(34, Endian.little), 16);
      expect(loaded.sublist(0, 4), original.sublist(0, 4));
      expect(loaded.sublist(8, 40), original.sublist(8, 40));
      for (var copy = 0; copy < 3; copy++) {
        expect(
          loaded.sublist(44 + copy * dataSize, 44 + (copy + 1) * dataSize),
          original.sublist(44),
        );
      }
      final unchanged = await rootBundle.load(SoundKind.end.asset);
      expect(unchanged.buffer.asUint8List(), original);
    },
  );
}
