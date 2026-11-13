import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:machine_goldens/baselines.dart';

import 'support/repo.dart';

void main() {
  late TestRepo repo;
  late Directory cache;

  setUp(() async {
    repo = await TestRepo.create();
    cache = Directory.systemTemp.createTempSync('machine_goldens_cache');
  });

  tearDown(() {
    repo.delete();
    cache.deleteSync(recursive: true);
  });

  Future<ProcessResult> report() => Process.run(
    '${MachineKey.flutterRoot()}/bin/cache/dart-sdk/bin/dart',
    [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '${Directory.current.path}/bin/report.dart',
    ],
    workingDirectory: repo.dir,
    environment: {cacheEnvironmentVariable: cache.path},
  );

  test('after work, report lists the failed goldens and the ones this branch '
      'changed, each with its diff', () async {
    await repo.git(['checkout', '--quiet', '-b', 'feature']);
    repo
      ..write('test/goldens/a.png', 'a, as the branch draws it')
      ..write('test/goldens/c.png', 'c, new');
    final diff = '${repo.dir}/test/failures/b_isolatedDiff.png';
    GoldenReport(repo.dir)
      ..record(ReportEntry(
        golden: 'test/goldens/b.png',
        outcome: GoldenOutcome.failed,
        baseline: "this machine's baseline",
        diffs: [diff],
        at: DateTime.now(),
      ))
      ..record(ReportEntry(
        golden: 'test/goldens/a.png',
        outcome: GoldenOutcome.changed,
        baseline: 'its own render',
        diffs: ['${repo.dir}/test/failures/a_isolatedDiff_branch.png'],
        at: DateTime.now(),
      ));

    final result = await report();

    expect(result.exitCode, 1, reason: '${result.stderr}');
    final out = result.stdout as String;
    expect(out, contains("Failed against this machine's baseline (1):\n"
        '  test/goldens/b.png\n    $diff\n'));
    expect(out, contains('Changed by this branch since '));
    expect(out, contains('  test/goldens/a.png\n'
        '    ${repo.dir}/test/failures/a_isolatedDiff_branch.png\n'));
    expect(out, contains('  test/goldens/c.png\n'
        '    not compared yet: run its test for a diff\n'));
  });

  test('with nothing failed or changed, report says so and exits 0', () async {
    final result = await report();

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains("No golden failed against this machine's baseline."));
    expect(result.stdout, contains('No golden changed by this branch.'));
  });
}
