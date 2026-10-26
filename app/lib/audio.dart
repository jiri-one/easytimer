import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'timer_engine.dart';

extension SoundKindAudio on SoundKind {
  String get asset => switch (this) {
    SoundKind.alarm => 'assets/audio/threesecbeep.wav',
    SoundKind.end => 'assets/audio/hit.wav',
  };
}

double gainOf(int percent) {
  final linear = percent / 100;
  return linear * linear;
}

Future<Uint8List> loadSound(SoundKind kind) async {
  final asset = await rootBundle.load(kind.asset);
  final bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  if (kind == SoundKind.alarm) return bytes;

  // Both bundled WAVs have a 44-byte PCM header with no other chunks.
  final size = ByteData.sublistView(bytes).getUint32(40, Endian.little);
  final repeated = Uint8List(44 + size * 3)..setRange(0, 44, bytes);
  for (var copy = 0; copy < 3; copy++) {
    repeated.setRange(44 + copy * size, 44 + (copy + 1) * size, bytes, 44);
  }
  ByteData.sublistView(repeated)
    ..setUint32(4, repeated.length - 8, Endian.little)
    ..setUint32(40, size * 3, Endian.little);
  return repeated;
}
