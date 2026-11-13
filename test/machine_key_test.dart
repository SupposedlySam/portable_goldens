import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:machine_goldens/baselines.dart';

import 'support/repo.dart';

void main() {
  test("this machine's key holds its OS version, arch, engine and Dart", () {
    final key = MachineKey.current();

    expect(key.os, Platform.operatingSystem);
    expect(key.osVersion, Platform.operatingSystemVersion);
    if (Platform.isMacOS) expect(key.osVersion, contains('(Build '));
    expect(key.arch, isNotEmpty);
    expect(key.engineRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(Platform.version, startsWith(key.dartVersion));
  });

  test('a change to any value names another folder', () {
    final key = fakeKey();
    final changed = [
      fakeKey(osVersion: 'Version 26.6.2 (Build 25G83)'),
      for (final json in [
        {...key.toJson(), 'os': 'linux'},
        {...key.toJson(), 'arch': 'macos_x64'},
        {...key.toJson(), 'engineRevision': '0' * 40},
        {...key.toJson(), 'dartVersion': '3.14.0'},
      ])
        MachineKey.fromJson(json),
    ];

    expect(fakeKey().id, key.id);
    expect(key.id, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect({for (final other in changed) other.id}, hasLength(changed.length));
    expect(changed.map((other) => other.id), isNot(contains(key.id)));
  });

  group('the engine revision', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('machine_goldens_sdk'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String content) => File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    test("is the cache's stamp, ahead of the checkout's version file", () {
      write('bin/cache/engine.stamp', 'from-the-cache\n');
      write('bin/internal/engine.version', 'from-the-checkout\n');

      expect(MachineKey.engineRevisionOf(root.path), 'from-the-cache');
    });

    test("is the checkout's version file when the cache has no stamp", () {
      write('bin/internal/engine.version', 'from-the-checkout\n');

      expect(MachineKey.engineRevisionOf(root.path), 'from-the-checkout');
    });

    test('is unknown in a folder that is no SDK, and the key says so', () {
      expect(MachineKey.engineRevisionOf(root.path), isNull);
      expect(
        MachineKey.current(environment: {'FLUTTER_ROOT': root.path})
            .engineRevision,
        isNull,
      );
    });
  });

  test('the SDK is FLUTTER_ROOT, or the folder above the executable\'s '
      'bin/cache', () {
    expect(
      MachineKey.flutterRoot(environment: {'FLUTTER_ROOT': '/sdk'}),
      '/sdk',
    );
    final exe = Platform.resolvedExecutable;
    expect(
      MachineKey.flutterRoot(environment: const {}),
      exe.substring(0, exe.lastIndexOf('/bin/cache/')),
    );
  });
}
