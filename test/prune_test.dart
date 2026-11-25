import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/command_runner.dart';
import 'package:portable_goldens/src/git/commit_reachability.dart';
import 'package:portable_goldens/src/prune/prune_policy.dart';
import 'package:portable_goldens/src/store/exclusive_lock.dart';
import 'package:portable_goldens/src/store/file_entries.dart';

import 'support/repo.dart';

final now = DateTime.now();
DateTime daysAgo(num days) =>
    now.subtract(Duration(minutes: (days * 24 * 60).round()));

void main() {
  late Directory cache;

  setUp(
    () => cache = Directory.systemTemp.createTempSync('portable_goldens_prune'),
  );
  tearDown(() => cache.deleteSync(recursive: true));

  Future<Built> render(Directory into) async {
    File('${into.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('rendered');
    return const Built(['test/goldens/a.png'], 'fake');
  }

  // [commit]'s baselines for [unit] under [key], last used [usedDaysAgo].
  Future<CommitBaselines> cached(
    String commit, {
    String unit = 'root',
    MachineKey? key,
    num usedDaysAgo = 0,
  }) async {
    final baselines = BaselineStore.open(
      cache.path,
      key ?? fakeKey(),
    ).at(commit, unit);
    await baselines.fill(render);
    baselines.markerFile.setLastModifiedSync(daysAgo(usedDaysAgo));
    return baselines;
  }

  group('the store records use', () {
    test('opening it marks a manifest it did not just write used', () {
      final written = BaselineStore.manifestIn(
        BaselineStore.open(cache.path, fakeKey()).machineDir,
      );
      // The same folder in another cache, last opened 40 days ago, which
      // this process has not opened yet: use is recorded once a process.
      final elsewhere = Directory('${cache.path}/elsewhere');
      final manifest = File(
        '${elsewhere.path}/${nameOf(written.parent)}/${nameOf(written)}',
      )..createSync(recursive: true);
      written.copySync(manifest.path);
      manifest.setLastModifiedSync(daysAgo(40));

      BaselineStore.open(elsewhere.path, fakeKey(osVersion: 'another'));
      expect(
        manifest.lastModifiedSync().isBefore(daysAgo(39)),
        isTrue,
        reason: 'another key leaves it as it was',
      );
      BaselineStore.open(elsewhere.path, fakeKey());
      expect(manifest.lastModifiedSync().isAfter(daysAgo(1)), isTrue);
    });

    test(
      'reading a baseline marks the marker used, and a miss marks nothing',
      () async {
        final baselines = await cached('c0ffee', usedDaysAgo: 40);

        expect(baselines.baseline('test/goldens/none.png'), isNull);
        expect(baselines.lastUsed!.isBefore(daysAgo(39)), isTrue);
        expect(baselines.baseline('test/goldens/a.png'), isNotNull);
        expect(baselines.lastUsed!.isAfter(daysAgo(1)), isTrue);
      },
    );

    test(
      'without a marker, the last use is the newest thing the unit left',
      () async {
        final commitDir = Directory('${cache.path}/k/c0ffee')
          ..createSync(recursive: true);
        final baselines = CommitBaselines(commitDir, 'c0ffee', 'root');
        expect(baselines.lastUsed, isNull);
        File('${commitDir.path}/root.failed')
          ..writeAsStringSync('{}')
          ..setLastModifiedSync(daysAgo(3));
        File('${commitDir.path}/root.lock')
          ..writeAsStringSync('')
          ..setLastModifiedSync(daysAgo(5));

        expect(
          baselines.lastUsed!.difference(daysAgo(3)).inMinutes.abs(),
          lessThan(2),
        );
      },
    );
  });

  test("a unit's entries are named back to it, a dot in its name or not", () {
    String? unit(String name, {bool dir = true}) =>
        CommitBaselines.unitOf(name, isDirectory: dir);

    expect(unit('root'), 'root');
    expect(unit('packages__my.app'), 'packages__my.app');
    expect(unit('.root.tmp-12-34'), 'root');
    expect(unit('.root.tmp-12-34-checkout'), 'root');
    expect(unit('.packages__my.app.tmp-12-34'), 'packages__my.app');
    expect(unit('root.failed', dir: false), 'root');
    expect(unit('packages__my.app.lock', dir: false), 'packages__my.app');
    expect(unit('.DS_Store', dir: false), isNull);
    expect(unit('notes.txt', dir: false), isNull);
    expect(unit('.hidden'), isNull);
    expect(unit('.lock', dir: false), isNull);
  });

  group('removing a unit', () {
    test('takes everything of it, and the commit folder once it is empty; '
        "another unit's stays", () async {
      final app = await cached('c0ffee', unit: 'app');
      final root = await cached('c0ffee');
      File('${root.commitDir.path}/root.failed').writeAsStringSync('{}');
      Directory('${root.commitDir.path}/.root.tmp-1-1-checkout').createSync();

      expect(await root.remove(), isTrue);
      expect(root.entries, isEmpty);
      expect(app.isComplete, isTrue);
      expect(root.commitDir.existsSync(), isTrue);

      expect(await app.remove(), isTrue);
      expect(root.commitDir.existsSync(), isFalse);
    });

    test(
      'is refused, removing nothing, while this process holds its lock',
      () async {
        final root = await cached('c0ffee');
        final lock = ExclusiveLock(File('${root.commitDir.path}/root.lock'));

        late bool removed;
        await lock.hold(() async => removed = await root.remove());

        expect(removed, isFalse);
        expect(root.isComplete, isTrue);
        expect(await lock.tryHold(() async {}), isTrue, reason: 'given back');
      },
    );

    final dart = '${FlutterSdk.current()?.root}/bin/cache/dart-sdk/bin/dart';

    test('is refused while another process builds it', () async {
      final log = File('${cache.path}/builds.log');
      final release = File('${cache.path}/release');
      final building = await Process.start(dart, [
        '--packages=.dart_tool/package_config.json',
        'test/support/fill_main.dart',
        cache.path,
        log.path,
        release.path,
      ]);
      final out = building.stdout.transform(utf8.decoder).join();
      for (var i = 0; i < 1500 && !log.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(log.existsSync(), isTrue, reason: 'the build never started');
      final baselines = BaselineStore.open(
        cache.path,
        fakeKey(),
      ).at('c0ffee', 'root');

      final removed = await baselines.remove();
      release.createSync();

      expect(removed, isFalse);
      expect(await building.exitCode, 0);
      expect((await out).trim(), startsWith('rendered by'));
      expect(baselines.isComplete, isTrue);
    });
  });

  group('reachability', () {
    late TestRepo repo;
    late GitRepo git;

    setUp(() async {
      repo = await TestRepo.create();
      git = (await GitRepo.open(repo.dir))!;
    });
    tearDown(() => repo.delete());

    test('a commit on a branch is reachable; amended away, unreachable; '
        'one the repository lacks, absent', () async {
      final first = await repo.git(['rev-parse', 'HEAD']);
      repo.write('c.txt', 'c');
      final amended = await repo.commit('second');
      await repo.git(['commit', '--quiet', '--amend', '-m', 'second, again']);
      final reach = await CommitReachability.of(git);

      expect(await reach.reachabilityOf(first), Reachability.reachable);
      expect(await reach.reachabilityOf(amended), Reachability.unreachable);
      expect(await reach.reachabilityOf('1' * 40), Reachability.absent);
    });

    test("a detached worktree's HEAD reaches its commit, a build's throwaway "
        'checkout does not', () async {
      repo.write('c.txt', 'c');
      final detached = await repo.commit('detached');
      repo.write('d.txt', 'd');
      final rendered = await repo.commit('rendered');
      await repo.git(['reset', '--quiet', '--hard', 'HEAD~2']);
      final outside = Directory.systemTemp.createTempSync(
        'portable_goldens_wt',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      await repo.git([
        'worktree',
        'add',
        '--detach',
        '${outside.path}/work',
        detached,
      ]);
      // What a build killed half way leaves registered.
      final commitDir = '${outside.path}/k/$rendered';
      Directory(commitDir).createSync(recursive: true);
      await repo.git([
        'worktree',
        'add',
        '--detach',
        '$commitDir/.root.tmp-1-2-checkout',
        rendered,
      ]);

      final reach = await CommitReachability.of(git);

      expect(await reach.reachabilityOf(detached), Reachability.reachable);
      expect(await reach.reachabilityOf(rendered), Reachability.unreachable);
    });

    test('without a repository, every commit is unknown', () async {
      expect(
        await CommitReachability.none().reachabilityOf('1' * 40),
        Reachability.unknown,
      );
    });
  });

  group('the policy', () {
    final policy = PrunePolicy(unusedFor: const Duration(days: 30), now: now);

    test('removes whatever was unused for the limit', () {
      for (final reach in Reachability.values) {
        expect(
          policy.reasonToRemove(daysAgo(31), reach),
          'unused for 31 days',
          reason: reach.name,
        );
        if (reach != Reachability.unreachable) {
          expect(policy.reasonToRemove(daysAgo(29), reach), isNull);
        }
      }
    });

    test('removes an unreachable commit unused for a day, and only that', () {
      expect(
        policy.reasonToRemove(daysAgo(2), Reachability.unreachable),
        startsWith('no branch, tag or checkout here has the commit'),
      );
      expect(
        policy.reasonToRemove(daysAgo(0.5), Reachability.unreachable),
        isNull,
        reason: 'a test may be reading it now',
      );
      for (final reach in [
        Reachability.reachable,
        Reachability.absent,
        Reachability.unknown,
      ]) {
        expect(policy.reasonToRemove(daysAgo(2), reach), isNull);
      }
    });

    test('keeps what has nothing on disk, and a machine folder opened '
        'recently', () {
      expect(policy.reasonToRemove(null, Reachability.unreachable), isNull);
      expect(policy.reasonToRemoveMachine(daysAgo(29)), isNull);
      expect(policy.reasonToRemoveMachine(daysAgo(31)), contains('31 days'));
    });
  });

  group('prune', () {
    late TestRepo here;
    late TestRepo other;

    setUp(() async {
      here = await TestRepo.create();
      other = await TestRepo.create();
    });
    tearDown(() {
      here.delete();
      other.delete();
    });

    Future<(int, String, String)> prune(
      List<String> args, {
      String? dir,
    }) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runPortableGoldens(
        'prune',
        args,
        context: CommandContext(
          packageDir: dir ?? here.dir,
          out: out,
          err: err,
          environment: {
            ...testGitEnvironment,
            cacheEnvironmentVariable: cache.path,
          },
          goldens: () => fail('prune opens no session'),
        ),
      );
      return (code, '$out', '$err');
    }

    // Commits in both repositories, one rebased away in each, and the
    // baselines of each in the one cache the two share.
    Future<Map<String, CommitBaselines>> twoRepositories() async {
      final kept = await here.git(['rev-parse', 'HEAD']);
      here.write('c.txt', 'c');
      final amended = await here.commit('amended away');
      await here.git(['commit', '--quiet', '--amend', '-m', 'again']);
      final idleHead = await here.git(['rev-parse', 'HEAD']);
      other.write('o.txt', 'o');
      final otherGone = await other.commit("other's, amended away");
      await other.git(['commit', '--quiet', '--amend', '-m', 'again']);
      final oldKey = fakeKey(osVersion: 'before the update');
      final old = await cached(kept, key: oldKey, usedDaysAgo: 45);
      BaselineStore.manifestIn(old.commitDir.parent)
          .setLastModifiedSync(daysAgo(45));
      return {
        'kept': await cached(kept, usedDaysAgo: 3),
        'amended': await cached(amended, usedDaysAgo: 2),
        'amendedToday': await cached(amended, unit: 'app', usedDaysAgo: 0.2),
        'idle': await cached(idleHead, usedDaysAgo: 31),
        'otherGone': await cached(otherGone, usedDaysAgo: 5),
        'old': old,
      };
    }

    test('removes the unused and the unreachable, and never another '
        "repository's commit for being unknown here", () async {
      final units = await twoRepositories();
      File('${cache.path}/notes.txt').writeAsStringSync('mine');

      final (code, out, err) = await prune(const []);

      expect(code, 0, reason: err);
      expect(err, isEmpty);
      expect(units['amended']!.entries, isEmpty);
      expect(units['idle']!.entries, isEmpty);
      expect(units['old']!.commitDir.parent.existsSync(), isFalse);
      expect(units['kept']!.isComplete, isTrue);
      expect(units['amendedToday']!.isComplete, isTrue, reason: 'used today');
      expect(units['otherGone']!.isComplete, isTrue);
      expect(File('${cache.path}/notes.txt').existsSync(), isTrue);
      expect(out, contains('no branch, tag or checkout here has the commit'));
      expect(out, contains('unused for 31 days'));
      expect(out, contains('unused for 45 days'));
      expect(out, contains('no baselines left, and not opened for 45 days'));
      expect(out, contains('Freed '));
      expect(out, contains('(4 folders); kept 3 baselines.'));
      expect(
        out,
        contains('1 kept baseline of commits this repository does not have'),
      );

      // From the other repository, its own commit is unreachable.
      final (_, fromOther, _) = await prune(const [], dir: other.dir);
      expect(units['otherGone']!.entries, isEmpty, reason: fromOther);
      expect(units['kept']!.isComplete, isTrue);
    });

    test('an unopened machine folder stays while anything is left in it: '
        'baselines kept, baselines in use, or what this package did not '
        'write', () async {
      final head = await here.git(['rev-parse', 'HEAD']);
      Future<CommitBaselines> old(String os, {num usedDaysAgo = 45}) async {
        final baselines = await cached(
          head,
          key: fakeKey(osVersion: os),
          usedDaysAgo: usedDaysAgo,
        );
        BaselineStore.manifestIn(baselines.commitDir.parent)
            .setLastModifiedSync(daysAgo(45));
        return baselines;
      }

      final kept = await old('kept', usedDaysAgo: 3);
      final building = await old('building');
      final foreign = await old('foreign');
      File('${foreign.commitDir.parent.path}/notes.txt')
          .writeAsStringSync('mine');
      final gone = await old('gone');

      late (int, String, String) pruned;
      await ExclusiveLock(File('${building.commitDir.path}/root.lock'))
          .hold(() async => pruned = await prune(const []));
      final (code, out, _) = pruned;

      expect(code, 0);
      expect(kept.isComplete, isTrue);
      expect(building.isComplete, isTrue);
      expect(out, contains('in use'));
      expect(foreign.entries, isEmpty);
      expect(
        File('${foreign.commitDir.parent.path}/notes.txt').existsSync(),
        isTrue,
      );
      expect(
        gone.commitDir.parent.existsSync(),
        isFalse,
        reason: 'the positive control',
      );
      expect(
        [kept, building, foreign].map((b) => b.commitDir.parent.existsSync()),
        everyElement(isTrue),
      );
    });

    test('--dry-run says the same and removes nothing', () async {
      final units = await twoRepositories();
      final before = {
        for (final MapEntry(:key, :value) in units.entries)
          key: value.entries.length,
      };

      final (code, out, _) = await prune(['--dry-run']);

      expect(code, 0);
      expect(out, startsWith('Would prune ${cache.path}'));
      expect(RegExp('would remove ').allMatches(out), hasLength(4));
      expect(out, contains('Would free '));
      expect({
        for (final MapEntry(:key, :value) in units.entries)
          key: value.entries.length,
      }, before);
    });

    test('--older-than moves the age limit', () async {
      final units = await twoRepositories();

      await prune(['--older-than', '4']);

      expect(units['kept']!.isComplete, isTrue, reason: 'used 3 days ago');
      expect(units['otherGone']!.entries, isEmpty, reason: 'used 5 days ago');
    });

    test('outside a repository, only age removes', () async {
      final units = await twoRepositories();
      final outside = Directory.systemTemp.createTempSync('portable_goldens_x');
      addTearDown(() => outside.deleteSync(recursive: true));

      final (_, out, _) = await prune(const [], dir: outside.path);

      expect(out, contains('Not in a git repository'));
      expect(units['amended']!.isComplete, isTrue);
      expect(units['idle']!.entries, isEmpty);
      expect(out, contains('4 kept baselines of commits git could not judge'));
    });

    test('an empty or missing cache has nothing to remove', () async {
      cache.deleteSync(recursive: true);

      final (code, out, _) = await prune(const []);
      cache.createSync();

      expect(code, 0);
      expect(out, contains('Nothing to remove; kept 0 baselines.'));
    });

    test('--older-than must be a whole number of days', () async {
      for (final bad in ['0', '-1', '1.5', 'week']) {
        final (code, _, err) = await prune(['--older-than', bad]);
        expect(code, 64, reason: bad);
        expect(
          err,
          contains('--older-than must be a whole number of days, 1 or more'),
        );
      }
    });
  });
}
