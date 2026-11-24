import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/command_runner.dart';

import 'support/repo.dart';

void main() {
  late TestRepo repo;
  late Directory cache;

  setUp(() async {
    repo = await TestRepo.create();
    cache = Directory.systemTemp.createTempSync('portable_goldens_cache');
  });

  tearDown(() {
    repo.delete();
    cache.deleteSync(recursive: true);
  });

  Future<(int, String, String)> report([List<String> args = const []]) async {
    final out = StringBuffer();
    final err = StringBuffer();
    const environment = {'FLUTTER_ROOT': '/fake/flutter'};
    final code = await runPortableGoldens(
      'report',
      args,
      context: CommandContext(
        packageDir: repo.dir,
        out: out,
        err: err,
        environment: environment,
        goldens: () => MachineGoldens(
          packageDir: repo.dir,
          environment: environment,
          key: fakeKey(),
          cacheRoot: cache.path,
        ),
      ),
    );
    return (code, '$out', '$err');
  }

  // A branch that changed a.png and added c.png, after a run in which b.png
  // failed and a.png was compared as a branch change.
  Future<String> workOnABranch() async {
    await repo.git(['checkout', '--quiet', '-b', 'feature']);
    repo
      ..write('test/goldens/a.png', 'a, as the branch draws it')
      ..write('test/goldens/c.png', 'c, new');
    final diff = '${repo.dir}/test/failures/b_isolatedDiff.png';
    GoldenReport(repo.dir)
      ..record(
        ReportEntry(
          golden: 'test/goldens/b.png',
          outcome: GoldenOutcome.failed,
          baseline: "this machine's baseline",
          diffs: [diff],
          at: DateTime.now(),
        ),
      )
      ..record(
        ReportEntry(
          golden: 'test/goldens/a.png',
          outcome: GoldenOutcome.changed,
          baseline: 'its own render',
          diffs: ['${repo.dir}/test/failures/a_isolatedDiff_branch.png'],
          at: DateTime.now(),
        ),
      );
    return diff;
  }

  test('after work, report lists the failed goldens and the ones this branch '
      'changed, each with its diff', () async {
    final diff = await workOnABranch();

    final (code, out, err) = await report();

    expect(code, 1, reason: err);
    expect(
      out,
      contains(
        "Failed against this machine's baseline (1):\n"
        '  test/goldens/b.png\n    $diff\n',
      ),
    );
    expect(out, contains('Changed by this branch since '));
    expect(
      out,
      contains(
        '  test/goldens/a.png\n'
        '    ${repo.dir}/test/failures/a_isolatedDiff_branch.png\n',
      ),
    );
    expect(
      out,
      contains(
        '  test/goldens/c.png\n'
        '    not compared yet: run its test for a diff\n',
      ),
    );
  });

  test('with nothing failed or changed, report says so and exits 0', () async {
    final (code, out, err) = await report();

    expect(code, 0, reason: err);
    expect(out, contains("No golden failed against this machine's baseline."));
    expect(out, contains('No golden changed by this branch.'));
  });

  test('a failure whose png was deleted since is not a failure now', () async {
    await workOnABranch();
    File('${repo.dir}/test/goldens/b.png').deleteSync();

    final (code, out, _) = await report();

    expect(code, 0);
    expect(out, contains("No golden failed against this machine's baseline."));
    expect(out, contains('test/goldens/a.png'));
  });

  test('--json writes the same summary as one document', () async {
    final diff = await workOnABranch();
    final base = (await repo.git(['merge-base', 'HEAD', 'main'])).trim();

    final (code, out, err) = await report(['--json']);

    expect(code, 1, reason: err);
    expect(jsonDecode(out), {
      'base': base,
      'failed': [
        {
          'golden': 'test/goldens/b.png',
          'diffs': [diff],
        },
      ],
      'changed': [
        {
          'golden': 'test/goldens/a.png',
          'compared': true,
          'baseline': 'its own render',
          'diffs': ['${repo.dir}/test/failures/a_isolatedDiff_branch.png'],
        },
        {
          'golden': 'test/goldens/c.png',
          'compared': false,
          'diffs': <String>[],
        },
      ],
    });
  });
}
