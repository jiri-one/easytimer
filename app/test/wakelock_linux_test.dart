@TestOn('vm')
library;

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:easytimer/screen_wake_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class _Request extends DBusObject {
  _Request(super.path);

  int closes = 0;
  bool failClose = false;
  bool closed = false;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'org.freedesktop.portal.Request' ||
        call.name != 'Close') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    closes++;
    if (failClose) {
      failClose = false;
      return DBusMethodErrorResponse.failed('temporary failure');
    }
    closed = true;
    return DBusMethodSuccessResponse();
  }
}

class _Portal extends DBusObject {
  _Portal() : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  final calls = <DBusMethodCall>[];
  final requests = <_Request>[];
  bool failInhibit = false;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'org.freedesktop.portal.Inhibit' ||
        call.name != 'Inhibit') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    calls.add(call);
    if (failInhibit) {
      failInhibit = false;
      return DBusMethodErrorResponse.failed('temporary failure');
    }
    final request = _Request(
      DBusObjectPath(
        '/org/freedesktop/portal/desktop/request/test/r${requests.length}',
      ),
    );
    requests.add(request);
    await client!.registerObject(request);
    return DBusMethodSuccessResponse([request.path]);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
  // Let the reply update the plugin's handle before the next assertion.
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

void main() {
  final address = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
  final isolated =
      Platform.isLinux &&
      address != null &&
      address.startsWith('unix:path=/tmp/') &&
      Platform.environment['EASYTIMER_PRIVATE_DBUS'] == address;

  test(
    'real Linux plugin uses portal idle inhibition and closes every handle',
    () async {
      final service = DBusClient.session();
      final client = DBusClient.session();
      final portal = _Portal();
      final wake = ScreenWakeLock();
      final previous = wakelockPlusPlatformInstance;
      try {
        expect(
          await service.requestName(
            'org.freedesktop.portal.Desktop',
            flags: {DBusRequestNameFlag.doNotQueue},
          ),
          DBusRequestNameReply.primaryOwner,
        );
        await service.registerObject(portal);
        final plugin = WakelockPlusLinuxPlugin(
          client: client,
          appNameGetter: () async => 'EasyTimer test',
        );
        wakelockPlusPlatformInstance = plugin;

        wake.setEnabled(true);
        wake.setEnabled(true);
        wake.setEnabled(false);
        await _until(
          () => portal.requests.isNotEmpty && portal.requests.single.closed,
        );
        expect(portal.calls, hasLength(1));
        expect(portal.calls.single.signature, DBusSignature('sua{sv}'));
        expect(portal.calls.single.values, [
          const DBusString(''),
          const DBusUint32(8),
          DBusDict.stringVariant({
            'reason': const DBusString('EasyTimer test: wakelock active'),
          }),
        ]);
        expect(await plugin.enabled, isFalse);

        portal.failInhibit = true;
        wake.setEnabled(true);
        await _until(() => portal.calls.length == 2);
        expect(await plugin.enabled, isFalse);
        wake.setEnabled(true);
        await _until(() => portal.requests.length == 2);
        expect(await plugin.enabled, isTrue);
        final request = portal.requests.last..failClose = true;
        wake.setEnabled(false);
        await _until(() => request.closes == 1);
        expect(await plugin.enabled, isTrue);
        wake.setEnabled(false);
        await _until(() => request.closed);
        expect(request.closes, 2);
        expect(await plugin.enabled, isFalse);
        expect(portal.requests.every((request) => request.closed), isTrue);
      } finally {
        wakelockPlusPlatformInstance = previous;
        await client.close();
        await service.close();
      }
    },
    skip: isolated ? false : 'Requires dbus-run-session with EASYTIMER_PRIVATE_DBUS equal to its /tmp bus address.',
  );
}
