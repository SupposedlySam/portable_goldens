import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

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
    final before = await session(
      FakeFlutter(),
    ).baselineFor('test/goldens/a.png') as MachineBaseline;

    final flutter = FakeFlutter();
    final updated = fakeKey(osVersion: 'Version 27.3 (Build 26C5)');
    final after = await session(
      flutter,
      key: updated,
    ).baselineFor('test/goldens/a.png') as MachineBaseline;

    expect(flutter.testRuns, hasLength(1));
    expect(after.keyId, isNot(before.keyId));
    expect(after.file.path, isNot(before.file.path));
    final manifest = File('${cache.path}/${updated.id}/manifest.json');
    expect(manifest.readAsStringSync(), contains('Version 27.3 (Build 26C5)'));
  });

  test(
    "the child runs the commit's own golden tests, told it is a child",
    () async {
      final flutter = FakeFlutter();

      await session(
        flutter,
        environment: {'FLUTTER_TEST': 'true'},
      ).baselineFor('test/goldens/a.png');

      final run = flutter.testRuns.single;
      expect(run.args, ['test', '--update-goldens', 'test/a_test.dart']);
      expect(run.env[childEnvironmentVariable], '1');
      expect(run.env.containsKey('FLUTTER_TEST'), isFalse);
    },
  );

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

  test('the builder itself refuses inside a build, before running anything, '
      'for a caller that skipped the session', () async {
    final head = await repo.git(['rev-parse', 'HEAD']);
    final calls = <String>[];
    final into = Directory('${cache.path}/into')..createSync();

    await expectLater(
      BaselineBuilder(
        repo: (await GitRepo.open(repo.dir))!,
        flutterRoot: '/fake/flutter',
        environment: const {childEnvironmentVariable: '1'},
        runProcess:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
            }) {
              calls.add('$executable ${arguments.join(' ')}');
              return FakeFlutter().call(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
              );
            },
      ).build(head, into),
      throwsA(
        isA<BuildFailure>().having(
          (f) => f.message,
          'message',
          startsWith('refused'),
        ),
      ),
    );
    expect(calls, isEmpty);
    expect(into.listSync(), isEmpty);
  });

  group('a golden this branch changed', () {
    late String branchPoint;

    setUp(() async {
      branchPoint = await repo.git(['rev-parse', 'HEAD']);
      await repo.git(['checkout', '--quiet', '-b', 'feature']);
    });

    test(
      "committed on the branch: this machine's render of its commit, "
      "with this machine's render from before the branch for the report",
      () async {
        repo.write('test/goldens/a.png', 'a, as the branch draws it');
        final commit = await repo.commit('a changes');
        final goldens = session(FakeFlutter());

        final baseline = await goldens.baselineFor('test/goldens/a.png');
        final change = await goldens.branchChange('test/goldens/a.png');

        expect(
          baseline,
          isA<MachineBaseline>().having((m) => m.commit, 'commit', commit),
        );
        expect(change!.base, branchPoint);
        expect(
          String.fromCharCodes(change.image!),
          'rendered test/goldens/a.png at $branchPoint',
        );
      },
    );

    test(
      'a base that does not build here reports the png committed there',
      () async {
        repo.write('test/goldens/a.png', 'a, as the branch draws it');
        await repo.commit('a changes');

        final change = await session(FakeFlutter(testExitCode: 1))
            .branchChange('test/goldens/a.png');

        expect(String.fromCharCodes(change!.image!), 'committed a');
        expect(change.was, contains('the png committed at'));
      },
    );

    test(
      'uncommitted: the png in the working tree, and nothing is built',
      () async {
        repo.write('test/goldens/a.png', 'a, not committed');
        final flutter = FakeFlutter();

        expect(
          await session(flutter).baselineFor('test/goldens/a.png'),
          isA<WorkingTreeBaseline>(),
        );
        expect(flutter.testRuns, isEmpty);
      },
    );

    test('new: the png in the working tree, reported as new', () async {
      repo.write('test/goldens/c.png', 'c, new');
      final goldens = session(FakeFlutter());

      expect(
        await goldens.baselineFor('test/goldens/c.png'),
        isA<WorkingTreeBaseline>(),
      );
      final change = await goldens.branchChange('test/goldens/c.png');
      expect(change!.image, isNull);
      expect(change.was, 'new on this branch');
    });

    test(
      'and one it did not change is not, though main changed it since',
      () async {
        await repo.git(['checkout', '--quiet', 'main']);
        repo.write('test/goldens/b.png', 'b, as main draws it now');
        await repo.commit('main moves on');
        await repo.git(['checkout', '--quiet', 'feature']);
        // Measured from main's tip, b.png would be this branch's change.
        expect(
          await repo.git(['diff', '--name-only', 'main']),
          contains('test/goldens/b.png'),
        );

        final goldens = session(FakeFlutter());
        final baseline = await goldens.baselineFor('test/goldens/b.png');

        expect(await goldens.base, branchPoint);
        expect(
          baseline,
          isA<MachineBaseline>().having((m) => m.commit, 'commit', branchPoint),
        );
        expect(await goldens.changedByBranch('**/goldens/**/*.png'), isEmpty);
        expect(await goldens.branchChange('test/goldens/b.png'), isNull);
      },
    );

    test(
      'a stale origin/main does not stretch the branch back past main',
      () async {
        // origin/main was fetched before main's last commit, the branch point.
        await repo.git(['checkout', '--quiet', 'main']);
        final stale = await repo.git(['rev-parse', 'HEAD']);
        repo.write('test/goldens/b.png', 'b, as main draws it now');
        final fresh = await repo.commit('main moves on');
        await repo.git(['update-ref', 'refs/remotes/origin/main', stale]);
        await repo.git(['checkout', '--quiet', '-b', 'topic']);

        final goldens = session(FakeFlutter());

        expect(await goldens.base, fresh);
        expect(await goldens.changedByBranch('**/goldens/**/*.png'), isEmpty);
      },
    );
  });

  test("the build's checkout is beside its temporary folder in the cache, "
      'where a sweep finds it, and is gone afterwards', () async {
    final flutter = FakeFlutter();

    await session(flutter).baselineFor('test/goldens/a.png');

    final dir = flutter.testRuns.single.dir!;
    expect(dir, startsWith(cache.path));
    expect(dir, matches(RegExp(r'/\.root\.tmp-[0-9-]+-checkout/$')));
    expect(Directory(dir).existsSync(), isFalse);
    expect(await repo.git(['worktree', 'list']), isNot(contains('checkout')));
  });

  test('a build that fails is a loud failure naming the commit and the '
      'command', () async {
    final head = await repo.git(['rev-parse', 'HEAD']);

    await expectLater(
      session(FakeFlutter(testExitCode: 1)).baselineFor('test/goldens/a.png'),
      throwsA(
        isA<BuildFailure>()
            .having((f) => f.commit, 'commit', head)
            .having(
              (f) => f.command,
              'command',
              contains('test --update-goldens test/a_test.dart'),
            )
            .having((f) => f.output, 'output', contains('Some tests failed.')),
      ),
    );
  });

  test('a build that did not draw the golden fails; the image in the '
      'checkout is never taken for a render', () async {
    final flutter = FakeFlutter(renders: ['test/goldens/a.png']);

    await expectLater(
      session(flutter).baselineFor('test/goldens/b.png'),
      throwsA(
        isA<BuildFailure>().having(
          (f) => f.message,
          'message',
          contains('did not write test/goldens/b.png'),
        ),
      ),
    );
  });

  test('a commit that cannot be checked out compares with the committed '
      'image', () async {
    final baseline = await session(FakeFlutter(checkoutFails: true))
        .baselineFor('test/goldens/a.png');

    expect(
      baseline,
      isA<CommittedBaseline>().having(
        (c) => c.reason,
        'reason',
        contains('could not be checked out'),
      ),
    );
  });

  test(
    'a shallow clone compares with the committed image, since its '
    'boundary commit would pass for the one that last changed a golden',
    () async {
      repo.write('test/goldens/b.png', 'committed b, again');
      final head = await repo.commit('b moves');
      final shallow = Directory.systemTemp.createTempSync(
        'portable_goldens_shallow',
      );
      addTearDown(() => shallow.deleteSync(recursive: true));
      await Process.run('git', [
        'clone',
        '--quiet',
        '--depth',
        '1',
        'file://${repo.dir}',
        shallow.path,
      ]);
      // a.png's commit is not in the clone: log names the boundary instead.
      final log = await Process.run('git', [
        'log',
        '-1',
        '--format=%H',
        '--',
        'test/goldens/a.png',
      ], workingDirectory: shallow.path);
      expect((log.stdout as String).trim(), head);
      final flutter = FakeFlutter();

      final baseline = await MachineGoldens(
        packageDir: shallow.resolveSymbolicLinksSync(),
        environment: const {'FLUTTER_ROOT': '/fake/flutter'},
        key: fakeKey(),
        cacheRoot: cache.path,
        runProcess: flutter.call,
      ).baselineFor('test/goldens/a.png');

      expect(
        baseline,
        isA<CommittedBaseline>().having(
          (c) => c.reason,
          'reason',
          contains('the clone is shallow'),
        ),
      );
      expect(flutter.testRuns, isEmpty);
    },
  );

  test(
    'outside a git repository it compares with the committed image',
    () async {
      final plain = Directory.systemTemp.createTempSync(
        'portable_goldens_plain',
      );
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
    },
  );

  test(
    'missing lists the goldens without a baseline here, by commit',
    () async {
      final head = await repo.git(['rev-parse', 'HEAD']);
      final goldens = session(FakeFlutter());

      expect(await goldens.missing('**/goldens/**/*.png'), {
        head: ['test/goldens/a.png', 'test/goldens/b.png'],
      });
      await goldens.build(head);
      expect(await goldens.missing('**/goldens/**/*.png'), isEmpty);
    },
  );
}
