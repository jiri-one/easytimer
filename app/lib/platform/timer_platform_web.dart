import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../constants.dart';
import '../cue_policy.dart';
import '../timer_engine.dart';
import 'timer_platform.dart';

class _ScheduledSound {
  _ScheduledSound(
    this.revision,
    this.event,
    this.nodes,
    this.startMs,
    this.when,
    this.until,
  );

  final int revision;
  final SoundEvent event;
  final List<web.AudioBufferSourceNode> nodes;
  final int startMs;
  final double when;
  double until;
  bool played = false;

  (int, CueId) get key => (revision, event.id);
}

class PlatformBackend extends TimerPlatform {
  late final web.AudioContext _context;
  late final web.GainNode _gain;
  late final web.AudioBuffer _alarm;
  late final web.AudioBuffer _end;
  late final JSFunction _visibility;
  final _sources = <(int, CueId), _ScheduledSound>{};
  final _pending = <CueId, SoundEvent>{};
  final _policy = CuePolicy();
  int _revision = 0;
  MonotonicClock? _clock;
  double? _clockOffsetMs;
  bool _ready = false;
  bool _disposed = false;

  @override
  Future<void> initialize() async {
    _context = web.AudioContext(
      web.AudioContextOptions(latencyHint: 'interactive'.toJS),
    );
    _gain = _context.createGain()..connect(_context.destination);
    _context.onstatechange = ((web.Event event) => _reconcile()).toJS;
    _visibility = ((web.Event event) {
      if (web.document.visibilityState == 'visible') unawaited(_resume());
    }).toJS;
    web.document.addEventListener('visibilitychange', _visibility);
    final buffers = await Future.wait([_decode(alarmAsset), _decode(endAsset)]);
    if (_disposed) return;
    _alarm = buffers[0];
    _end = buffers[1];
    _ready = true;
    _reconcile();
  }

  Future<web.AudioBuffer> _decode(String path) async {
    final data = await rootBundle.load(path);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return _context.decodeAudioData(bytes.sublist(0).buffer.toJS).toDart;
  }

  @override
  void unlock() {
    // Browser authorization belongs to the input gesture's synchronous stack.
    if (!_disposed) unawaited(_resume());
  }

  Future<void> _resume() async {
    final revision = _revision;
    try {
      _reconcile();
      await _context.resume().toDart;
      if (revision == _revision) _reconcile();
    } catch (_) {
      // An interruption can require another user gesture.
    }
  }

  @override
  void schedule(List<SoundEvent> events, MonotonicClock clock) {
    if (_disposed) return;
    _clock = clock;
    for (final event in events) {
      if (!_policy.handled(event)) _pending[event.id] = event;
    }
    _reconcile();
  }

  void _recordPlayback(_ScheduledSound sound, double audioNow) {
    // A queued source can be interrupted before rendering any samples.
    if (sound.played || audioNow <= sound.when || sound.until <= sound.when) {
      return;
    }
    sound.played = true;
    if (sound.revision != _revision) return;
    _policy.started(sound.event, sound.startMs);
    _pending.remove(sound.event.id);
  }

  void _removeSound(_ScheduledSound sound, {bool stop = false}) {
    _sources.remove(sound.key);
    for (final node in sound.nodes) {
      node.onended = null;
      if (stop) node.stop();
      node.disconnect();
    }
  }

  void _reconcile() {
    final clock = _clock;
    if (_disposed || !_ready || clock == null) return;
    final now = clock.nowMs;
    final audioNow = _context.currentTime;
    final running = _context.state == 'running';
    final offset = audioNow * 1000 - now;
    // Render quantization is small; a suspended context can drift by seconds.
    final rebase =
        !running ||
        _clockOffsetMs == null ||
        (offset - _clockOffsetMs!).abs() > 20;
    for (final sound in _sources.values.toList()) {
      _recordPlayback(sound, audioNow);
      if (audioNow >= sound.until) {
        _removeSound(sound);
      } else if (rebase && !sound.played) {
        _removeSound(sound, stop: true);
      }
    }
    if (rebase) _clockOffsetMs = running ? offset : null;
    _pending.removeWhere((id, event) {
      final discard = _policy.handled(event) || _policy.expired(event, now);
      if (discard) {
        final sound = _sources[(_revision, id)];
        if (sound != null && !sound.played) _removeSound(sound, stop: true);
      }
      return discard;
    });
    if (!running) return;

    final events = _pending.values.toList()
      ..sort((a, b) => a.atMs.compareTo(b.atMs));
    for (final event in _policy.select(events, now)) {
      if (_sources.containsKey((_revision, event.id))) continue;
      final startMs = math.max(now, event.atMs);
      final when = audioNow + (startMs - now) / 1000;
      final buffer = event.kind == SoundKind.alarm ? _alarm : _end;
      final repeats = event.kind == SoundKind.end ? 3 : 1;
      final nodes = List.generate(repeats, (index) {
        return _context.createBufferSource()
          ..buffer = buffer
          ..connect(_gain)
          ..start(when + index * buffer.duration);
      });
      final sound = _ScheduledSound(
        _revision,
        event,
        nodes,
        startMs,
        when,
        when + buffer.duration * repeats,
      );
      // A later cue replaces an overlapping sound on the single audio stream.
      for (final other in _sources.values) {
        if (other.when <= when && other.until > when) {
          _cutOff(other, when);
        } else if (other.when > when && other.when < sound.until) {
          _cutOff(sound, other.when);
        }
      }
      _sources[sound.key] = sound;
      nodes.last.onended = ((web.Event event) {
        if (!identical(_sources[sound.key], sound)) return;
        _recordPlayback(sound, _context.currentTime);
        _removeSound(sound);
      }).toJS;
    }
  }

  void _cutOff(_ScheduledSound sound, double when) {
    sound.until = when;
    for (final source in sound.nodes) {
      source.stop(when);
    }
  }

  @override
  void cancel() {
    final audioNow = _context.currentTime;
    for (final sound in _sources.values.toList()) {
      _recordPlayback(sound, audioNow);
      if (sound.event.kind != SoundKind.end ||
          !sound.played ||
          audioNow >= sound.until) {
        _removeSound(sound, stop: true);
      }
    }
    _pending.clear();
    _policy.reset();
    _revision++;
    _clock = null;
    _clockOffsetMs = null;
  }

  @override
  void setVolume(int percent) {
    final volume = percent / 100;
    _gain.gain.value = volume * volume;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    for (final sound in _sources.values.toList()) {
      _removeSound(sound, stop: true);
    }
    keepAwake(false);
    _context.onstatechange = null;
    web.document.removeEventListener('visibilitychange', _visibility);
    unawaited(_context.close().toDart);
  }
}
