import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/build/path_overrides.dart';
import 'package:portable_goldens/src/git/package_location.dart';
import 'package:portable_goldens/src/machine/flutter_sdk.dart';

// The resolutions here are real: each fixture is resolved by `dart pub get
// --offline`, so the package_config.json read is the one pub writes, not one
// written to match the reader.
// A folder name that YAML, unquoted, would read as a comment and a mapping.
const farFolder = "far/it's #1: here";

void main() {
  late String outer;
  late String dart;

  setUpAll(() {
    final sdk = FlutterSdk.current();
    if (sdk == null) fail('no Flutter SDK found to run pub with');
    dart = sdk.dart;
  });

  setUp(() {
    outer = Directory.systemTemp
        .createTempSync('portable_goldens_overrides')
        .resolveSymbolicLinksSync();
  });

  tearDown(() => Directory(outer).deleteSync(recursive: true));

  void write(String path, String content) => File('$outer/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  void package(String dir, String name, {String dependencies = ''}) => write(
    '$dir/pubspec.yaml',
    'name: $name\nenvironment:\n  sdk: ^3.13.0\n'
        '${dependencies.isEmpty ? '' : 'dependencies:\n$dependencies'}',
  );

  Future<void> pubGet(String dir) async {
    final result = await Process.run(dart, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: '$outer/$dir');
    expect(
      result.exitCode,
      0,
      reason: 'pub get in $dir: ${result.stdout}${result.stderr}',
    );
  }

  PackageLocation at(String repo, String prefix) => PackageLocation(
    topLevel: '$outer/$repo',
    prefix: prefix,
    packageDir: '$outer/$repo/$prefix',
  );

  // A repository whose app, one level down, depends on a package beside it
  // in the repository, on one beside the repository, on one two levels out
  // in a folder whose name YAML must have quoted, and on one by its absolute
  // path, which needs no override.
  Future<void> app() async {
    package('repo/shared', 'shared');
    package('near', 'near');
    package(farFolder, 'far');
    package('absolute', 'absolute');
    package(
      'repo/app',
      'app',
      dependencies:
          '  shared:\n    path: ../shared\n'
          '  near:\n    path: ../../near\n'
          '  far:\n    path: "../../$farFolder"\n'
          '  absolute:\n    path: "$outer/absolute"\n',
    );
    await pubGet('repo/app');
  }

  test('each path dependency outside the repository is overridden by its '
      'absolute folder; one inside is not, nor the package itself', () async {
    await app();

    final overrides = PathOverrides.of(at('repo', 'app/'));

    expect(overrides.root, 'app/');
    expect(overrides.unread, isNull);
    expect(overrides.packages, {
      'far': '$outer/$farFolder',
      'near': '$outer/near',
    });
    expect(overrides.packages.keys, ['far', 'near'], reason: 'name order');
  });

  test('the written overrides let a checkout elsewhere resolve, as pub reads '
      'them', () async {
    await app();
    final overrides = PathOverrides.of(at('repo', 'app/'));
    // A checkout of the repository two levels deeper than it: its relative
    // paths reach nothing.
    package('a/b/checkout/shared', 'shared');
    write(
      'a/b/checkout/app/pubspec.yaml',
      File('$outer/repo/app/pubspec.yaml').readAsStringSync(),
    );

    final shown = overrides.writeInto('$outer/a/b/checkout');

    expect(shown, 'write <dir>/app/$overridesFileName overriding far, near');
    await pubGet('a/b/checkout/app');
    final config = File(
      '$outer/a/b/checkout/app/.dart_tool/package_config.json',
    ).readAsStringSync();
    expect(config, contains('"rootUri": "file://$outer/near"'));
    expect(config, contains('"rootUri": "${Uri.file('$outer/$farFolder')}'));
    expect(config, contains('"rootUri": "../../shared"'));
  });

  test("a workspace's overrides go at its root, where pub keeps its one "
      'resolution', () async {
    package('dep', 'dep');
    write(
      'repo/pubspec.yaml',
      'name: root\nenvironment:\n  sdk: ^3.13.0\nworkspace:\n  - packages/app\n',
    );
    write(
      'repo/packages/app/pubspec.yaml',
      'name: app\nenvironment:\n  sdk: ^3.13.0\nresolution: workspace\n'
          'dependencies:\n  dep:\n    path: ../../../dep\n',
    );
    await pubGet('repo');

    final overrides = PathOverrides.of(at('repo', 'packages/app/'));

    expect(overrides.root, '');
    expect(overrides.packages, {'dep': '$outer/dep'});
    Directory('$outer/checkout').createSync();
    expect(
      overrides.writeInto('$outer/checkout'),
      'write <dir>/$overridesFileName overriding dep',
    );
    expect(File('$outer/checkout/$overridesFileName').existsSync(), isTrue);
  });

  test('no resolution, and none outside the repository, write nothing', () {
    package('repo', 'app');
    final unresolved = PathOverrides.of(at('repo', ''));
    Directory('$outer/checkout').createSync();

    expect(unresolved.packages, isEmpty);
    expect(unresolved.unread, isNull);
    expect(unresolved.writeInto('$outer/checkout'), isNull);
    expect(Directory('$outer/checkout').listSync(), isEmpty);
  });

  test("a resolution above the top level is not this repository's", () async {
    package('dep', 'dep');
    package('app', 'app', dependencies: '  dep:\n    path: ../dep\n');
    await pubGet('app');
    // A repository below the resolved package: the search stops at its top.
    package('app/inner', 'inner');

    expect(PathOverrides.of(at('app/inner', '')).packages, isEmpty);
  });

  test('an unreadable resolution is said, not taken for one with nothing to '
      'override', () {
    package('repo', 'app');
    write('repo/.dart_tool/package_config.json', '{"packages": [{}]}');
    Directory('$outer/checkout').createSync();

    final overrides = PathOverrides.of(at('repo', ''));
    final shown = overrides.writeInto('$outer/checkout');

    expect(overrides.unread, contains('package_config.json'));
    expect(shown, startsWith('(no path overrides: '));
    expect(shown, contains('without a name and rootUri'));
    expect(Directory('$outer/checkout').listSync(), isEmpty);
  });

  test(
    "a commit's own overrides file is kept, and the command says so",
    () async {
      await app();
      write('checkout/app/$overridesFileName', "# the author's\n");

      final shown = PathOverrides.of(at('repo', 'app/'))
          .writeInto('$outer/checkout');

      expect(shown, contains("kept the commit's own <dir>/app/"));
      expect(shown, contains('far, near'));
      expect(
        File('$outer/checkout/app/$overridesFileName').readAsStringSync(),
        "# the author's\n",
      );
    },
  );

  test("a commit without the resolution's folder gets no overrides, and the "
      'command says so', () async {
    await app();
    Directory('$outer/checkout').createSync();

    final shown = PathOverrides.of(at('repo', 'app/'))
        .writeInto('$outer/checkout');

    expect(shown, '(no path overrides: the commit has no <dir>/app/)');
    expect(Directory('$outer/checkout').listSync(), isEmpty);
  });
}
