@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:easytimer/app.dart';
import 'package:easytimer/platform/timer_platform.dart';
import 'package:easytimer/settings.dart';
import 'package:easytimer/timer_engine.dart';
import 'package:easytimer/workout_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The public export selects the VM implementation during analysis.
// ignore: implementation_imports
import 'package:wakelock_plus/src/wakelock_plus_web_plugin.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web/web.dart' as web;

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _descriptor(JSObject object, JSString key);

@JS('Object.defineProperty')
external void _define(JSObject object, JSString key, JSObject descriptor);

@JS('Reflect.deleteProperty')
external void _delete(JSObject object, JSString key);

class _WakeRequest {
  _WakeRequest() {
    sentinel
      ..setProperty('type'.toJS, 'screen'.toJS)
      ..setProperty('released'.toJS, false.toJS)
      ..setProperty(
        'release'.toJS,
        (() {
          release();
          return Future<JSAny?>.value(null).toJS;
        }).toJS,
      );
  }

  final sentinel = web.EventTarget();
  final completion = Completer<JSObject>();
  bool granted = false;
  bool released = false;

  void grant() {
    granted = true;
    completion.complete(sentinel);
  }

  void release() {
    if (released) return;
    released = true;
    sentinel.setProperty('released'.toJS, true.toJS);
    sentinel.dispatchEvent(web.Event('release'));
  }
}

class _BrowserWakeFixture {
  final _originalWakeLock = _descriptor(web.window.navigator, 'wakeLock'.toJS);
  final _originalVisibility = _descriptor(web.document, 'visibilityState'.toJS);
  final requests = <_WakeRequest>[];
  final protocolErrors = <String>[];
  String visibility = 'visible';
  bool holdRequests = false;

  int get held => requests.where((r) => r.granted && !r.released).length;

  void install() {
    _define(
      web.window.navigator,
      'wakeLock'.toJS,
      JSObject()
        ..setProperty('configurable'.toJS, true.toJS)
        ..setProperty(
          'value'.toJS,
          JSObject()..setProperty(
            'request'.toJS,
            ((JSString type) {
              if (type.toDart != 'screen') {
                protocolErrors.add(
                  'Requested ${type.toDart} instead of screen',
                );
              }
              if (visibility != 'visible') {
                protocolErrors.add('Requested a wake lock while hidden');
              }
              if (held != 0 || requests.any((r) => !r.granted)) {
                protocolErrors.add('Overlapping wake acquisitions');
              }
              final request = _WakeRequest();
              requests.add(request);
              if (!holdRequests) request.grant();
              return request.completion.future.toJS;
            }).toJS,
          ),
        ),
    );
    _define(
      web.document,
      'visibilityState'.toJS,
      JSObject()
        ..setProperty('configurable'.toJS, true.toJS)
        ..setProperty('get'.toJS, (() => visibility.toJS).toJS),
    );
  }

  void visible(String value) {
    // EditableText also observes the intermediate inactive lifecycle state.
    web.window.dispatchEvent(web.Event('blur'));
    visibility = value;
    web.document.dispatchEvent(web.Event('visibilitychange'));
    if (value == 'visible') web.window.dispatchEvent(web.Event('focus'));
  }

  void hideAndRelease() {
    // The browser can release the sentinel before dispatching visibilitychange.
    web.window.dispatchEvent(web.Event('blur'));
    visibility = 'hidden';
    requests.last.release();
    web.document.dispatchEvent(web.Event('visibilitychange'));
  }

  void releasePendingAcquisitions() {
    holdRequests = false;
    for (final request in requests.where((r) => !r.granted)) {
      request.grant();
    }
  }

  void restore() {
    for (final (object, key, original) in <(JSObject, String, JSObject?)>[
      (web.window.navigator, 'wakeLock', _originalWakeLock),
      (web.document, 'visibilityState', _originalVisibility),
    ]) {
      if (original == null) {
        _delete(object, key.toJS);
      } else {
        _define(object, key.toJS, original);
      }
    }
  }
}

class _Clock implements MonotonicClock {
  @override
  int nowMs = 0;
}

class _MemoryPreferences implements SharedPreferences {
  final _values = <String, Object>{};

  @override
  Object? get(String key) => _values[key];

  @override
  Future<bool> setInt(String key, int value) async {
    _values[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SilentPlatform extends TimerPlatform {
  @override
  Future<void> initialize() async {}
  @override
  void schedule(List<SoundEvent> events) {}
  @override
  void cancel() {}
  @override
  void setVolume(int percent) {}
}

void _mockAssetManifest() {
  // Flutter's browser test runner has no flutter/assets platform handler.
  final binary = const StandardMessageCodec().encodeMessage(
    <String, Object>{},
  )!;
  final json = jsonEncode(base64Encode(Uint8List.sublistView(binary)));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        return switch (utf8.decode(Uint8List.sublistView(message!))) {
          'AssetManifest.bin' => binary,
          'AssetManifest.bin.json' => ByteData.sublistView(utf8.encode(json)),
          'FontManifest.json' => ByteData.sublistView(utf8.encode('[]')),
          _ => null,
        };
      });
}

late WidgetTester _wakeTester;

Future<void> _settleWakeLock() async {
  // Lifecycle callbacks also leave work in the binding's separate test zone.
  await _wakeTester.pump();
  await pumpEventQueue(times: 10);
  await _wakeTester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final browser = _BrowserWakeFixture();
  final previous = wakelockPlusPlatformInstance;
  var installed = false;

  setUpAll(() async {
    // This is the plugin's own switch for its asset URL on Flutter's test server.
    expect(
      const bool.fromEnvironment('WEB_PLUGIN_TESTS'),
      isTrue,
      reason: 'Run browser tests with --dart-define=WEB_PLUGIN_TESTS=true.',
    );
    browser.install();
    installed = true;
    wakelockPlusPlatformInstance = WakelockPlusWebPlugin();
    await WakelockPlus.disable();
    expect(
      globalContext.getProperty<JSBoolean>('nativeWakeLock'.toJS).toDart,
      isTrue,
    );
  });

  tearDownAll(() async {
    if (!installed) return;
    try {
      await WakelockPlus.disable();
    } finally {
      wakelockPlusPlatformInstance = previous;
      browser.restore();
    }
  });

  void wakeTest(
    String description,
    Future<void> Function(
      WorkoutController controller,
      _Clock clock,
      WidgetTester tester,
    )
    body,
  ) {
    testWidgets(description, (tester) async {
      _wakeTester = tester;
      browser.requests.clear();
      browser.protocolErrors.clear();
      browser.holdRequests = false;
      _mockAssetManifest();
      final clock = _Clock();
      final controller = WorkoutController(
        TimerSettings(_MemoryPreferences()),
        _SilentPlatform(),
        clock: clock,
      );
      await tester.pumpWidget(EasyTimerApp(controller: controller));
      try {
        (Object, StackTrace)? failure;
        await tester.runAsync(() async {
          try {
            // The test binding resets lifecycle independently of the browser.
            browser.visible('visible');
            await _settleWakeLock();
            await body(controller, clock, tester);
          } catch (error, stack) {
            failure = (error, stack);
          }
          try {
            controller.stop();
            browser.releasePendingAcquisitions();
            await _settleWakeLock();
            browser.visible('visible');
            await _settleWakeLock();
            expect(await WakelockPlus.enabled, isFalse);
            expect(browser.held, 0);
            expect(browser.protocolErrors, isEmpty);
          } catch (error, stack) {
            failure ??= (error, stack);
          }
        });
        // Report through the test zone; runAsync's FlutterError output can be
        // missing from the browser runner's terminal log.
        expect(tester.takeException(), isNull, reason: description);
        final captured = failure;
        if (captured != null) {
          debugPrint('Wake-lock failure: ${captured.$1}\n${captured.$2}');
          Error.throwWithStackTrace(captured.$1, captured.$2);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
    });
  }

  for (final (paused, focused) in [
    (false, true),
    (true, true),
    (false, false),
    (true, false),
  ]) {
    wakeTest(
      'real web plugin recovers after visibility release, paused=$paused, focused=$focused',
      (controller, clock, tester) async {
        var screenChanges = 0;
        controller.showingTimer.addListener(() => screenChanges++);
        controller.start(const WorkoutOptions());
        if (paused) controller.togglePause();
        await _settleWakeLock();
        expect(browser.requests, hasLength(1));
        expect(await WakelockPlus.enabled, isTrue);

        browser.hideAndRelease();
        await _settleWakeLock();
        expect(tester.binding.lifecycleState, AppLifecycleState.hidden);
        expect(await WakelockPlus.enabled, isFalse);
        expect(browser.requests, hasLength(1));
        clock.nowMs = 6000;

        if (focused) {
          browser.visible('visible');
        } else {
          // The pinned engine maps visibilitychange to resumed; exercise the
          // visible inactive state without injecting a focus/resume event.
          browser.visibility = 'visible';
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        }
        await _settleWakeLock();
        expect(
          tester.binding.lifecycleState,
          focused ? AppLifecycleState.resumed : AppLifecycleState.inactive,
        );
        expect(browser.requests, hasLength(2));
        expect(await WakelockPlus.enabled, isTrue);
        expect(browser.held, 1);
        expect(controller.showingTimer.value, isTrue);
        expect(screenChanges, 1);
        expect(
          controller.display.value.mode,
          paused ? TimerMode.paused : TimerMode.running,
        );
        expect(
          controller.display.value.phase,
          paused ? TimerPhase.prepare : TimerPhase.active,
        );
      },
    );
  }

  wakeTest(
    'focus resume reconciles a released lock without duplicating a held one',
    (controller, clock, tester) async {
      controller.start(const WorkoutOptions());
      await _settleWakeLock();
      web.window.dispatchEvent(web.Event('blur'));
      web.window.dispatchEvent(web.Event('focus'));
      await _settleWakeLock();
      expect(browser.requests, hasLength(1));
      expect(await WakelockPlus.enabled, isTrue);

      browser.requests.single.release();
      expect(await WakelockPlus.enabled, isFalse);
      web.window.dispatchEvent(web.Event('blur'));
      web.window.dispatchEvent(web.Event('focus'));
      await _settleWakeLock();
      expect(browser.requests, hasLength(2));
      expect(controller.showingTimer.value, isTrue);
      expect(await WakelockPlus.enabled, isTrue);
    },
  );

  wakeTest('rapid Stop/Start serializes pending web acquisition', (
    controller,
    clock,
    tester,
  ) async {
    browser.holdRequests = true;
    controller.start(const WorkoutOptions());
    await _settleWakeLock();
    expect(browser.requests, hasLength(1));
    expect(browser.requests.single.granted, isFalse);

    controller.stop();
    controller.start(const WorkoutOptions());
    await _settleWakeLock();
    expect(browser.requests, hasLength(1));
    browser.requests.first.grant();
    await _settleWakeLock();
    expect(browser.requests, hasLength(2));
    expect(browser.requests.first.released, isTrue);
    expect(browser.requests.last.granted, isFalse);
    browser.requests.last.grant();
    await _settleWakeLock();
    expect(controller.showingTimer.value, isTrue);
    expect(await WakelockPlus.enabled, isTrue);
    expect(browser.held, 1);
  });

  for (final finish in [false, true]) {
    wakeTest('pending web acquisition is released after finish=$finish', (
      controller,
      clock,
      tester,
    ) async {
      browser.holdRequests = true;
      controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      await _settleWakeLock();
      expect(browser.requests, hasLength(1));
      if (finish) {
        clock.nowMs = 10000;
        controller.refresh(recoverWakeLock: true);
      } else {
        controller.stop();
      }
      browser.requests.single.grant();
      await _settleWakeLock();
      expect(browser.requests, hasLength(1));
      expect(browser.requests.single.released, isTrue);
      expect(controller.showingTimer.value, isFalse);
      expect(await WakelockPlus.enabled, isFalse);
    });

    wakeTest('returning to a stopped or expired workout stays off: $finish', (
      controller,
      clock,
      tester,
    ) async {
      browser.visible('hidden');
      await _settleWakeLock();
      expect(tester.binding.lifecycleState, AppLifecycleState.hidden);
      browser.visible('visible');
      await _settleWakeLock();
      expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
      expect(browser.requests, isEmpty);
      controller.start(const WorkoutOptions(active: 5, rest: 0, sets: 1));
      await _settleWakeLock();
      expect(browser.requests, hasLength(1));
      expect(await WakelockPlus.enabled, isTrue);
      browser.hideAndRelease();
      await _settleWakeLock();
      expect(tester.binding.lifecycleState, AppLifecycleState.hidden);
      expect(await WakelockPlus.enabled, isFalse);
      if (finish) {
        clock.nowMs = 10000;
      } else {
        controller.stop();
      }
      browser.visible('visible');
      await _settleWakeLock();
      expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
      expect(controller.showingTimer.value, isFalse);
      expect(
        controller.display.value.mode,
        finish ? TimerMode.complete : TimerMode.stopped,
      );
      expect(browser.requests, hasLength(1));
      expect(await WakelockPlus.enabled, isFalse);
    });
  }
}
