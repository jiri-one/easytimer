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

String? _privateBusSkipReason(
  Map<String, String> environment,
  String Function(String) resolvePath,
) {
  final address = environment['DBUS_SESSION_BUS_ADDRESS'];
  if (address == null ||
      address.isEmpty ||
      environment['EASYTIMER_PRIVATE_DBUS'] != address) {
    return 'Set EASYTIMER_PRIVATE_DBUS exactly to DBUS_SESSION_BUS_ADDRESS.';
  }
  final directory = environment['EASYTIMER_TEST_SOCKET_DIR'];
  if (directory == null || !directory.startsWith('/') || directory == '/') {
    return 'Set EASYTIMER_TEST_SOCKET_DIR to an absolute test-owned directory.';
  }
  try {
    final parsed = DBusAddress(address);
    final socket = parsed.properties['path'];
    if (parsed.transport != 'unix' ||
        address.contains(';') ||
        parsed.properties.keys.any((key) => key != 'path' && key != 'guid') ||
        socket == null ||
        !socket.startsWith('/')) {
      return 'Requires one Unix path address, with only an optional guid.';
    }
    final root = resolvePath(directory);
    final path = resolvePath(socket);
    // Prefix checks alone allow a test path to alias the real session bus.
    if (root != directory || path != socket) {
      return 'Socket and directory must use canonical paths without symlinks.';
    }
    if (path.startsWith('/run/user/') || !path.startsWith('$root/')) {
      return 'Socket must stay inside EASYTIMER_TEST_SOCKET_DIR, outside /run/user.';
    }
  } on FormatException {
    return 'Invalid DBUS_SESSION_BUS_ADDRESS.';
  } on FileSystemException {
    return 'Socket and EASYTIMER_TEST_SOCKET_DIR must exist on disk.';
  }
  return null;
}

void main() {
  String? privateBusSkipReason() {
    if (!Platform.isLinux) return 'Requires Linux.';
    final reason = _privateBusSkipReason(
      Platform.environment,
      (path) => File(path).resolveSymbolicLinksSync(),
    );
    if (reason != null &&
        Platform.environment.containsKey('EASYTIMER_PRIVATE_DBUS')) {
      return 'Requested private D-Bus test rejected: $reason';
    }
    return reason;
  }

  test('private bus guard requires declared canonical socket paths', () {
    const directory = '/tmp/wakelock-test';
    const address = 'unix:path=$directory/bus';
    const aliases = {
      '$directory/link': '/run/user/1000/bus',
      '$directory/../bus': '/tmp/bus',
      '/tmp/alias': '/run/user/1000',
      '/tmp/alias/bus': '/run/user/1000/bus',
    };
    String resolvePath(String path) => aliases[path] ?? path;
    for (final (bus, root, allowed) in [
      (address, directory, true),
      ('$address,guid=0123456789abcdef0123456789abcdef', directory, true),
      ('unix:path=/cache/test/bus', '/cache/test', true),
      (address, '', false),
      (address, '/', false),
      ('unix:path=/run/user/1000/bus', '/run/user/1000', false),
      ('unix:path=%2frun%2fuser%2f1000%2fbus', '/run/user/1000', false),
      ('unix:path=$directory/link', directory, false),
      ('unix:path=$directory/../bus', directory, false),
      ('unix:path=/tmp/alias/bus', '/tmp/alias', false),
      ('unix:path=$directory-other/bus', directory, false),
      ('$address;unix:path=/run/user/1000/bus', directory, false),
      ('$address,path=/run/user/1000/bus', directory, false),
      ('$address,abstract=bus', directory, false),
      ('tcp:host=localhost,port=1234', directory, false),
    ]) {
      final environment = {
        'DBUS_SESSION_BUS_ADDRESS': bus,
        'EASYTIMER_PRIVATE_DBUS': bus,
        'EASYTIMER_TEST_SOCKET_DIR': root,
      };
      expect(
        _privateBusSkipReason(environment, resolvePath),
        allowed ? isNull : isNotNull,
        reason: '$bus in $root',
      );
      if (allowed) {
        environment.remove('EASYTIMER_PRIVATE_DBUS');
        expect(_privateBusSkipReason(environment, resolvePath), isNotNull);
        environment['EASYTIMER_PRIVATE_DBUS'] = 'mismatch';
        expect(_privateBusSkipReason(environment, resolvePath), isNotNull);
      }
    }
  });

  test(
    'real Linux plugin uses portal idle inhibition and closes every handle',
    () async {
      expect(privateBusSkipReason(), isNull);
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
    skip: privateBusSkipReason() ?? false,
  );
}
