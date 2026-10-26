import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:easytimer/timer_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject object, JSString key);

@JS('Object.defineProperty')
external void _define(JSObject object, JSString key, JSObject descriptor);

@JS('Reflect.deleteProperty')
external void _delete(JSObject object, JSString key);

Future<void> flushBrowserPromises() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class BrowserFixture {
  final _originalContext = globalContext.getProperty<JSAny?>(
    'AudioContext'.toJS,
  );
  final _originalVisibility = _descriptor(web.document, 'visibilityState'.toJS);
  late final context = FakeAudioContext(this);
  final gain = FakeGain();
  final starts = <FakeSource>[];
  final nodes = <FakeSource>[];
  final played = <FakeSource>[];
  final buffers = <FakeBuffer>[];
  var visibility = 'visible';
  var resumeCalls = 0;
  var holdResume = false;
  var failResume = false;
  Completer<JSAny?>? _resume;

  void install() {
    globalContext.setProperty(
      'AudioContext'.toJS,
      ((JSAny? options) => context.js).toJS,
    );
    _define(
      web.document,
      'visibilityState'.toJS,
      JSObject()
        ..setProperty('configurable'.toJS, true.toJS)
        ..setProperty('get'.toJS, (() => visibility.toJS).toJS),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (_) async => ByteData(1));
  }

  List<double> get startTimes => [for (final node in starts) node.when!];
  List<double> get liveStarts => [
    for (final node in starts)
      if (!node.disconnected) node.when!,
  ];

  void state(String value) {
    context.state = value;
    context.onstatechange?.callAsFunction(null, web.Event('statechange'));
  }

  void visible(String value) {
    visibility = value;
    web.document.dispatchEvent(web.Event('visibilitychange'));
  }

  void resolveResume() {
    state('running');
    _resume!.complete(null);
    _resume = null;
  }

  void advance(double time, {bool deliverEnded = true}) {
    if (context.state != 'running') throw StateError('Audio is suspended');
    context.currentTime = time;
    for (final node in nodes) {
      if (node.when == null || node.ended || node.disconnected) continue;
      final until = math.min(node.when! + node.buffer.duration, node.stopAt);
      if (!node.rendered && time > node.when! && until > node.when!) {
        node.rendered = true;
        played.add(node);
      }
      if (deliverEnded && time >= until) {
        node.ended = true;
        node.onended?.callAsFunction(null, web.Event('ended'));
      }
    }
  }

  void restore() {
    globalContext.setProperty('AudioContext'.toJS, _originalContext);
    final original = _originalVisibility;
    if (original == null) {
      _delete(web.document, 'visibilityState'.toJS);
    } else {
      _define(web.document, 'visibilityState'.toJS, original);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  }
}

class FakeAudioContext {
  FakeAudioContext(this.fixture);

  final BrowserFixture fixture;
  late final js = createJSInteropWrapper(this);
  @JSExport()
  String state = 'running';
  @JSExport()
  double currentTime = 0;
  @JSExport()
  final JSObject destination = JSObject();
  @JSExport()
  JSFunction? onstatechange;

  @JSExport()
  JSObject createGain() => fixture.gain.js;

  @JSExport()
  JSPromise<JSObject> decodeAudioData(JSArrayBuffer data) {
    final buffer = fixture.buffers.isEmpty
        ? FakeBuffer(SoundKind.alarm, 3.2)
        : FakeBuffer(SoundKind.end, 0.25);
    fixture.buffers.add(buffer);
    return Future.value(buffer.js).toJS;
  }

  @JSExport()
  JSObject createBufferSource() {
    final node = FakeSource(fixture);
    fixture.nodes.add(node);
    return node.js;
  }

  @JSExport()
  JSPromise<JSAny?> resume() {
    fixture.resumeCalls++;
    if (fixture.failResume) {
      return Future<JSAny?>.error(StateError('gesture required')).toJS;
    }
    if (fixture.holdResume) {
      fixture._resume ??= Completer<JSAny?>();
      return fixture._resume!.future.toJS;
    }
    fixture.state('running');
    return Future<JSAny?>.value(null).toJS;
  }

  @JSExport()
  JSPromise<JSAny?> close() {
    state = 'closed';
    return Future<JSAny?>.value(null).toJS;
  }
}

class FakeBuffer {
  FakeBuffer(this.kind, this.duration);

  final SoundKind kind;
  @JSExport()
  double duration;
  late final js = createJSInteropWrapper(this);
}

class FakeGain {
  late final js = createJSInteropWrapper(this);
  @JSExport()
  final gain = JSObject()..setProperty('value'.toJS, 1.toJS);
  @JSExport()
  void connect(JSObject destination) {}

  double get value => gain.getProperty<JSNumber>('value'.toJS).toDartDouble;
}

class FakeSource {
  FakeSource(this.fixture);

  final BrowserFixture fixture;
  late final js = createJSInteropWrapper(this);
  late FakeBuffer buffer;
  JSObject? connectedTo;
  double? when;
  double stopAt = double.infinity;
  bool rendered = false;
  bool disconnected = false;
  bool ended = false;
  @JSExport()
  JSFunction? onended;

  @JSExport('buffer')
  set jsBuffer(JSObject value) {
    buffer = fixture.buffers.firstWhere((buffer) => buffer.js == value);
  }

  @JSExport()
  void connect(JSObject gain) => connectedTo = gain;

  @JSExport()
  void disconnect() => disconnected = true;

  @JSExport()
  void start(double time) {
    when = time;
    fixture.starts.add(this);
  }

  @JSExport()
  void stop([double? time]) => stopAt = time ?? fixture.context.currentTime;
}
