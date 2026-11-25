import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';
import 'package:portable_goldens/src/cli/command_runner.dart';
import 'package:yaml/yaml.dart';

import 'support/repo.dart';

// One smoke test per executable, as a consumer runs it: the in-process
// tests drive the commands, and this proves `bin/` hands them the process's
// arguments and turns their result into its exit code.
void main() {
  late TestRepo repo;

  setUp(() async => repo = await TestRepo.create());
  tearDown(() => repo.delete());

  Future<ProcessResult> dartRun(String executable, List<String> args) =>
      Process.run('${FlutterSdk.current()?.root}/bin/cache/dart-sdk/bin/dart', [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/bin/$executable.dart',
        ...args,
      ], workingDirectory: repo.dir);

  // Read as pub reads it, not by lines: Git for Windows checks the file out
  // with CRLF line ends, which a line pattern did not match (CI, 2026-11-25).
  test('every command has its bin/ file and its pubspec executable', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final listed = pubspec['executables'] as YamlMap;
    final names = [for (final c in commands) c.name];

    expect(names, isNotEmpty);
    expect(listed.keys, unorderedEquals(names));
    for (final name in names) {
      expect(File('bin/$name.dart').existsSync(), isTrue, reason: name);
    }
  });

  for (final executable in [for (final c in commands) c.name]) {
    test('$executable: --help exits 0, a bad option exits 64', () async {
      final help = await dartRun(executable, ['--help']);
      expect(help.exitCode, 0, reason: '${help.stderr}');
      expect(help.stdout, contains('portable_goldens:$executable'));

      final bad = await dartRun(executable, ['--bogus']);
      expect(bad.exitCode, 64);
      expect(bad.stderr, contains('unknown option --bogus'));
    });
  }
}
