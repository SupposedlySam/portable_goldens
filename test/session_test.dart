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

  MachineGoldens session(
    FakeFlutter flutter, {
    MachineKey? key,
    Map<String, String> environment = const {},
  }) => MachineGoldens(
    packageDir: repo.dir,
    environment: {'FLUTTER_ROOT': '/fake/flutter', ...environment},
    key: key ?? fakeKey(),
    cacheRoot: cache.path,
    runProcess: flutter.call,
  );

  test("a golden compares with this machine's render of the commit that "
      'last changed it', () async {
    final first = await repo.git(['rev-parse', 'HEAD']);
    repo.write('test/goldens/b.png', 'committed b, again');
    final second = await repo.commit('b moves');
    final goldens = session(FakeFlutter());

    final a = await goldens.baselineFor('test/goldens/a.png');
    final b = await goldens.baselineFor('${repo.dir}/test/goldens/b.png');

    expect(a, isA<MachineBaseline>().having((m) => m.commit, 'commit', first));
    expect(
      (a as MachineBaseline).file.readAsStringSync(),
      'rendered test/goldens/a.png at $first',
    );
    expect(b, isA<MachineBaseline>().having((m) => m.commit, 'commit', second));
    expect(
      (b as MachineBaseline).file.readAsStringSync(),
      'rendered test/goldens/b.png at $second',
    );
  });

  test("one build per commit renders all of that commit's goldens, and the "
      'next process reuses it', () async {
    final flutter = FakeFlutter();
    final goldens = session(flutter);

    await goldens.baselineFor('test/goldens/a.png');
    await goldens.baselineFor('test/goldens/b.png');
    expect(flutter.testRuns, hasLength(1));

    final next = FakeFlutter();
    await session(next).baselineFor('test/goldens/b.png');
    expect(next.testRuns, isEmpty);
  });

  test('an OS update makes every baseline stale: the next run builds again, '
      'into a folder of its own', () async {
    final before = await session(FakeFlutter()).baselineFor(
      'test/goldens/a.png',
    ) as MachineBaseline;

    final flutter = FakeFlutter();
    final updated = fakeKey(osVersion: 'Version 27.3 (Build 26C5)');
    final after = await session(flutter, key: updated).baselineFor(
      'test/goldens/a.png',
    ) as MachineBaseline;

    expect(flutter.testRuns, hasLength(1));
    expect(after.keyId, isNot(before.keyId));
    expect(after.file.path, isNot(before.file.path));
    final manifest = File('${cache.path}/${updated.id}/manifest.json');
    expect(manifest.readAsStringSync(), contains('Version 27.3 (Build 26C5)'));
  });

  test("the child runs the commit's own golden tests, told it is a child",
      () async {
    final flutter = FakeFlutter();

    await session(flutter, environment: {'FLUTTER_TEST': 'true'})
        .baselineFor('test/goldens/a.png');

    final run = flutter.testRuns.single;
    expect(run.args, ['test', '--update-goldens', 'test/a_test.dart']);
    expect(run.env[childEnvironmentVariable], '1');
    expect(run.env.containsKey('FLUTTER_TEST'), isFalse);
  });

  test('a run inside a build never builds: it compares with the committed '
      'image', () async {
    final flutter = FakeFlutter();

    final baseline = await session(
      flutter,
      environment: {childEnvironmentVariable: '1'},
    ).baselineFor('test/goldens/a.png');

    expect(baseline, isA<CommittedBaseline>());
    expect(flutter.testRuns, isEmpty);
  });

  group('a golden this branch changed is its own baseline', () {
    setUp(() => repo.git(['checkout', '--quiet', '-b', 'feature']));

    test('committed on the branch', () async {
      repo.write('test/goldens/a.png', 'a, as the branch draws it');
      await repo.commit('a changes');
      final flutter = FakeFlutter();

      final baseline = await session(flutter).baselineFor('test/goldens/a.png');

      expect(baseline, isA<BranchChangedBaseline>());
      expect(flutter.testRuns, isEmpty);
    });

    test('uncommitted', () async {
      repo.write('test/goldens/a.png', 'a, not committed');

      expect(
        await session(FakeFlutter()).baselineFor('test/goldens/a.png'),
        isA<BranchChangedBaseline>(),
      );
    });

    test('new', () async {
      repo.write('test/goldens/c.png', 'c, new');

      expect(
        await session(FakeFlutter()).baselineFor('test/goldens/c.png'),
        isA<BranchChangedBaseline>(),
      );
    });

    test('and one it did not change is not, though main changed it since',
        () async {
      final branchPoint = await repo.git(['rev-parse', 'HEAD']);
      await repo.git(['checkout', '--quiet', 'main']);
      repo.write('test/goldens/b.png', 'b, as main draws it now');
      await repo.commit('main moves on');
      await repo.git(['checkout', '--quiet', 'feature']);
      // Measured from main's tip, b.png would be this branch's change.
      expect(await repo.git(['diff', '--name-only', 'main']),
          contains('test/goldens/b.png'));

      final goldens = session(FakeFlutter());
      final baseline = await goldens.baselineFor('test/goldens/b.png');

      expect(await goldens.base, branchPoint);
      expect(baseline,
          isA<MachineBaseline>().having((m) => m.commit, 'commit', branchPoint));
      expect(await goldens.changedByBranch('**/goldens/**/*.png'), isEmpty);
    });
  });

  test('a build that fails is a loud failure naming the commit and the '
      'command', () async {
    final head = await repo.git(['rev-parse', 'HEAD']);

    await expectLater(
      session(FakeFlutter(testExitCode: 1)).baselineFor('test/goldens/a.png'),
      throwsA(
        isA<BuildFailure>()
            .having((f) => f.commit, 'commit', head)
            .having((f) => f.command, 'command',
                contains('test --update-goldens test/a_test.dart'))
            .having((f) => f.output, 'output', contains('Some tests failed.')),
      ),
    );
  });

  test('a build that did not draw the golden fails; the image in the '
      'checkout is never taken for a render', () async {
    final flutter = FakeFlutter(renders: ['test/goldens/a.png']);

    await expectLater(
      session(flutter).baselineFor('test/goldens/b.png'),
      throwsA(isA<BuildFailure>().having(
        (f) => f.message, 'message', contains('did not write test/goldens/b.png'),
      )),
    );
  });

  test('a commit that cannot be checked out compares with the committed '
      'image', () async {
    final baseline = await session(FakeFlutter(checkoutFails: true))
        .baselineFor('test/goldens/a.png');

    expect(baseline, isA<CommittedBaseline>().having(
      (c) => c.reason, 'reason', contains('could not be checked out'),
    ));
  });

  test('outside a git repository it compares with the committed image',
      () async {
    final plain = Directory.systemTemp.createTempSync('machine_goldens_plain');
    addTearDown(() => plain.deleteSync(recursive: true));
    final flutter = FakeFlutter();

    final baseline = await MachineGoldens(
      packageDir: plain.path,
      environment: const {'FLUTTER_ROOT': '/fake/flutter'},
      key: fakeKey(),
      cacheRoot: cache.path,
      runProcess: flutter.call,
    ).baselineFor('test/goldens/a.png');

    expect(baseline, isA<CommittedBaseline>());
    expect(flutter.testRuns, isEmpty);
  });

  test('missing lists the goldens without a baseline here, by commit',
      () async {
    final head = await repo.git(['rev-parse', 'HEAD']);
    final goldens = session(FakeFlutter());

    expect(await goldens.missing('**/goldens/**/*.png'), {
      head: ['test/goldens/a.png', 'test/goldens/b.png'],
    });
    await goldens.build(head);
    expect(await goldens.missing('**/goldens/**/*.png'), isEmpty);
  });
}
