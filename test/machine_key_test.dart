import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

import 'support/repo.dart';

void main() {
  test("this machine's key holds its OS version, arch, engine, framework "
      'and Dart', () {
    final key = MachineKey.current();

    expect(key.os, Platform.operatingSystem);
    expect(key.osVersion, Platform.operatingSystemVersion);
    if (Platform.isMacOS) expect(key.osVersion, contains('(Build '));
    expect(key.arch, isNotEmpty);
    expect(key.engineRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(key.frameworkRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
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
        {...key.toJson(), 'frameworkRevision': '0' * 40},
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

    setUp(
      () => root = Directory.systemTemp.createTempSync('portable_goldens_sdk'),
    );
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

  group('the framework revision', () {
    late Directory root;
    const sha = '6a19cca56475dbfba1478ee68d7bd0c2ef891da1';

    setUp(
      () => root = Directory.systemTemp.createTempSync('portable_goldens_sdk'),
    );
    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String content) => File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    test("is the commit the checkout's branch names, loose or packed", () {
      write('.git/HEAD', 'ref: refs/heads/stable\n');
      write('.git/packed-refs', '# pack-refs\n$sha refs/heads/stable\n');
      expect(MachineKey.frameworkRevisionOf(root.path), sha);

      write('.git/refs/heads/stable', '${'1' * 40}\n');
      expect(MachineKey.frameworkRevisionOf(root.path), '1' * 40);
    });

    test('is a detached HEAD itself', () {
      write('.git/HEAD', '$sha\n');

      expect(MachineKey.frameworkRevisionOf(root.path), sha);
    });

    test("is the tool's version file without a checkout, else unknown", () {
      expect(MachineKey.frameworkRevisionOf(root.path), isNull);

      write('bin/cache/flutter.version.json', '{"frameworkRevision": "$sha"}');
      expect(MachineKey.frameworkRevisionOf(root.path), sha);
    });

    test(
      "matches git's own answer for this SDK",
      () async {
        final sdk = MachineKey.flutterRoot()!;
        final git = await Process.run('git', [
          'rev-parse',
          'HEAD',
        ], workingDirectory: sdk);

        expect(
          MachineKey.frameworkRevisionOf(sdk),
          (git.stdout as String).trim(),
        );
      },
      skip: Directory('${MachineKey.flutterRoot()}/.git').existsSync()
          ? false
          : 'the SDK is not a git checkout',
    );
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
