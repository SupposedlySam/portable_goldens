import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

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

  for (final executable in ['prepare', 'report']) {
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
