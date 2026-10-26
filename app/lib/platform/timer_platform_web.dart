import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import '../audio.dart';
import '../cue_policy.dart';
import '../timer_engine.dart';
import 'timer_platform.dart';

class _ScheduledSound {
  _ScheduledSound(this.revision, this.event, this.node, this.when, this.until);

  final int revision;
  final SoundEvent event;
  final web.AudioBufferSourceNode node;
  final double when;
  double until;
  bool played = false;

  (int, CueId) get key => (revision, event.id);
}

class PlatformBackend extends TimerPlatform {
  PlatformBackend(this._clock)
    : _context = web.AudioContext(
        web.AudioContextOptions(latencyHint: 'interactive'.toJS),
      ) {
    _gain = _context.createGain()..connect(_context.destination);
    _activation = ((web.Event event) => unawaited(_resume())).toJS;
    _visibility = ((web.Event event) {
      if (web.document.visibilityState == 'visible') unawaited(_resume());
    }).toJS;
  }

  static const _activationEvents = ['pointerdown', 'pointerup', 'touchend'];
  final MonotonicClock _clock;
  final web.AudioContext _context;
  late final web.GainNode _gain;
  late final web.AudioBuffer _alarm;
  late final web.AudioBuffer _end;
  late final JSFunction _activation;
  late final JSFunction _visibility;
  final _sources = <(int, CueId), _ScheduledSound>{};
  final _policy = CuePolicy();
  int _revision = 0;
  double? _clockOffsetMs;
  bool _ready = false;
  bool _disposed = false;

  @override
  Future<void> initialize() async {
    _context.onstatechange = ((web.Event event) => _reconcile()).toJS;
    for (final type in _activationEvents) {
      web.document.addEventListener(type, _activation, true.toJS);
    }
    // Flutter's window keyboard handler stops propagation before the document.
    web.window.addEventListener('keydown', _activation, true.toJS);
    web.document.addEventListener('visibilitychange', _visibility, true.toJS);
    final buffers = await Future.wait([
      _decode(SoundKind.alarm),
      _decode(SoundKind.end),
    ]);
    if (_disposed) return;
    _alarm = buffers[0];
    _end = buffers[1];
    _ready = true;
    _reconcile();
  }

  Future<web.AudioBuffer> _decode(SoundKind kind) async {
    final bytes = await loadSound(kind);
    return _context.decodeAudioData(bytes.sublist(0).buffer.toJS).toDart;
  }

  Future<void> _resume() async {
    if (_disposed) return;
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
  void schedule(List<SoundEvent> events) {
    if (_disposed) return;
    _policy.merge(events);
    _reconcile();
  }

  void _recordPlayback(_ScheduledSound sound, double audioNow) {
    // A queued source can be interrupted before rendering any samples.
    if (sound.played || audioNow <= sound.when || sound.until <= sound.when) {
      return;
    }
    sound.played = true;
    if (sound.revision != _revision) return;
    _policy.started(sound.event);
  }

  void _removeSound(_ScheduledSound sound, {bool stop = false}) {
    _sources.remove(sound.key);
    sound.node.onended = null;
    if (stop) sound.node.stop();
    sound.node.disconnect();
  }

  void _reconcile() {
    if (_disposed || !_ready) return;
    final now = _clock.nowMs;
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
    final events = _policy.due(now);
    final selected = {for (final event in events) event.id};
    for (final sound in _sources.values.toList()) {
      if (!sound.played && !selected.contains(sound.event.id)) {
        _removeSound(sound, stop: true);
      }
    }
    if (!running) return;

    for (final event in events) {
      if (_sources.containsKey((_revision, event.id))) continue;
      final startMs = math.max(now, event.atMs);
      final when = audioNow + (startMs - now) / 1000;
      final buffer = event.kind == SoundKind.alarm ? _alarm : _end;
      final node = _context.createBufferSource()
        ..buffer = buffer
        ..connect(_gain)
        ..start(when);
      final sound = _ScheduledSound(
        _revision,
        event,
        node,
        when,
        when + buffer.duration,
      );
      // SoundPool parity requires a single audible stream.
      for (final other in _sources.values) {
        if (other.when <= when && other.until > when) {
          _cutOff(other, when);
        } else if (other.when > when && other.when < sound.until) {
          _cutOff(sound, other.when);
        }
      }
      _sources[sound.key] = sound;
      node.onended = ((web.Event event) {
        if (!identical(_sources[sound.key], sound)) return;
        _recordPlayback(sound, _context.currentTime);
        _removeSound(sound);
      }).toJS;
    }
  }

  void _cutOff(_ScheduledSound sound, double when) {
    sound.until = when;
    sound.node.stop(when);
  }

  @override
  void cancel() {
    final audioNow = _context.currentTime;
    for (final sound in _sources.values.toList()) {
      _recordPlayback(sound, audioNow);
      if (!sound.event.kind.keepsOnCancel ||
          !sound.played ||
          audioNow >= sound.until) {
        _removeSound(sound, stop: true);
      }
    }
    _policy.reset();
    _revision++;
    _clockOffsetMs = null;
  }

  @override
  void setVolume(int percent) {
    _gain.gain.value = gainOf(percent);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final sound in _sources.values.toList()) {
      _removeSound(sound, stop: true);
    }
    _context.onstatechange = null;
    for (final type in _activationEvents) {
      web.document.removeEventListener(type, _activation, true.toJS);
    }
    web.window.removeEventListener('keydown', _activation, true.toJS);
    web.document.removeEventListener(
      'visibilitychange',
      _visibility,
      true.toJS,
    );
    unawaited(_context.close().toDart);
  }
}
