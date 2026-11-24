import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

import 'support/repo.dart';

void main() {
  late Directory cache;

  setUp(
    () => cache = Directory.systemTemp.createTempSync('portable_goldens_store'),
  );
  tearDown(() => cache.deleteSync(recursive: true));

  Future<Built> render(Directory into, {String content = 'rendered'}) async {
    File('${into.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return const Built(['test/goldens/a.png'], 'fake');
  }

  test('a baseline folder with no completion marker is treated as missing, '
      'and rebuilt', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    // What a build killed half way leaves: an image, and no marker.
    File('${store.at('c0ffee', 'root').dir.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('half written');

    expect(store.at('c0ffee', 'root').isComplete, isFalse);
    expect(store.at('c0ffee', 'root').baseline('test/goldens/a.png'), isNull);

    var builds = 0;
    await store.at('c0ffee', 'root').fill((into) {
      builds++;
      return render(into);
    });

    expect(builds, 1);
    expect(
      store
          .at('c0ffee', 'root')
          .baseline('test/goldens/a.png')!
          .readAsStringSync(),
      'rendered',
    );
  });

  test('a complete baseline is not built again', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    await store.at('c0ffee', 'root').fill(render);

    var builds = 0;
    await store.at('c0ffee', 'root').fill((into) {
      builds++;
      return render(into);
    });

    expect(builds, 0);
  });

  test('nothing is readable while a build is still writing', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    final writing = Completer<void>();
    final finish = Completer<void>();
    final fill = store.at('c0ffee', 'root').fill((into) async {
      final built = await render(into);
      writing.complete();
      await finish.future;
      return built;
    });

    await writing.future;
    expect(store.at('c0ffee', 'root').baseline('test/goldens/a.png'), isNull);
    finish.complete();
    await fill;
    expect(
      store.at('c0ffee', 'root').baseline('test/goldens/a.png'),
      isNotNull,
    );
  });

  test('a manifest that disagrees with the key throws the folder away', () {
    final key = fakeKey();
    final dir = Directory('${cache.path}/${key.id}');
    File('${dir.path}/manifest.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'os': 'macos',
          'osVersion': 'Version 26.6.2 (Build 25G83)',
          'arch': 'macos_arm64',
          'engineRevision': 'x',
          'dartVersion': '3.13.4',
        }),
      );
    File('${dir.path}/c0ffee/root/.complete').createSync(recursive: true);

    final store = BaselineStore.open(cache.path, key);

    expect(store.at('c0ffee', 'root').isComplete, isFalse);
    expect(
      File('${dir.path}/manifest.json').readAsStringSync(),
      contains('26B131'),
    );
  });

  test('an unreadable manifest is rewritten, and the baselines beside it are '
      'kept', () async {
    final key = fakeKey();
    await BaselineStore.open(cache.path, key).at('c0ffee', 'root').fill(render);
    // Half of one, as a reader saw it mid-write before writes were atomic.
    File('${cache.path}/${key.id}/manifest.json').writeAsStringSync('{"os":');

    final store = BaselineStore.open(cache.path, key);

    expect(
      store.at('c0ffee', 'root').baseline('test/goldens/a.png'),
      isNotNull,
    );
    expect(
      File('${cache.path}/${key.id}/manifest.json').readAsStringSync(),
      contains('26B131'),
    );
  });

  test('an image the marker does not list is not a baseline, nor is any '
      'image under a marker that does not parse', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    await store.at('c0ffee', 'root').fill(render);
    final dir = store.at('c0ffee', 'root').dir.path;
    File('$dir/test/goldens/b.png').writeAsStringSync('copied in by hand');

    expect(store.at('c0ffee', 'root').baseline('test/goldens/b.png'), isNull);

    File('$dir/.complete').writeAsStringSync('{"files": [');
    expect(store.at('c0ffee', 'root').isComplete, isFalse);
    expect(store.at('c0ffee', 'root').baseline('test/goldens/a.png'), isNull);
  });

  test('what a killed build left behind is swept by the next build', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    final commitDir = '${store.machineDir.path}/c0ffee';
    final left = [
      Directory('$commitDir/.root.tmp-1-1'),
      Directory('$commitDir/.root.tmp-1-1-checkout'),
    ];
    for (final dir in left) {
      File('${dir.path}/test/goldens/a.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('half written');
    }
    final otherUnit = Directory('$commitDir/.app.tmp-1-1')..createSync();

    await store.at('c0ffee', 'root').fill(render);

    for (final dir in left) {
      expect(dir.existsSync(), isFalse, reason: dir.path);
    }
    expect(otherUnit.existsSync(), isTrue);
  });

  test('a build that failed while another waited is not run again: the '
      'waiter gets the same failure', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    final started = Completer<void>();
    var builds = 0;
    Future<Built> failing(Directory into) async {
      builds++;
      started.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      throw const BuildFailure(
        commit: 'c0ffee',
        command: 'flutter test --update-goldens',
        message: 'exited 1',
      );
    }

    final first = store.at('c0ffee', 'root').fill(failing);
    await started.future;
    final second = store.at('c0ffee', 'root').fill(failing);

    await expectLater(first, throwsA(isA<BuildFailure>()));
    await expectLater(
      second,
      throwsA(
        isA<BuildFailure>().having((f) => f.message, 'message', 'exited 1'),
      ),
    );
    expect(builds, 1);
  });

  final dart = '${FlutterSdk.current()?.root}/bin/cache/dart-sdk/bin/dart';

  test('two processes filling the same baseline at once build it once: the '
      'second waits on the lock', () async {
    final log = File('${cache.path}/builds.log');
    final release = File('${cache.path}/release');
    final waiting = Completer<void>();
    Future<(int, String)> one() async {
      final process = await Process.start(dart, [
        '--packages=.dart_tool/package_config.json',
        'test/support/fill_main.dart',
        cache.path,
        log.path,
        release.path,
      ]);
      final out = process.stdout.transform(utf8.decoder).join();
      process.stderr.transform(utf8.decoder).listen((text) {
        if (text.contains('waiting for another build') &&
            !waiting.isCompleted) {
          waiting.complete();
        }
      });
      return (await process.exitCode, (await out).trim());
    }

    final runs = Future.wait([one(), one()]);
    // Held until the second has tried the lock and said so; a bound, so a
    // broken lock fails below rather than hanging.
    var contended = true;
    await waiting.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => contended = false,
    );
    release.createSync();
    final results = await runs;

    expect(contended, isTrue, reason: 'the second process never waited');
    for (final (code, _) in results) {
      expect(code, 0);
    }
    final builders = log.readAsLinesSync();
    expect(builders, hasLength(1));
    expect([
      for (final (_, out) in results) out,
    ], everyElement('rendered by ${builders.single}'));
  });

  test('processes opening a store with no manifest yet, all at once, keep '
      "each other's baselines", () async {
    final start = DateTime.now().add(const Duration(seconds: 2));
    final commits = [for (var i = 0; i < 6; i++) 'c0ffee$i'];

    final results = await Future.wait([
      for (final commit in commits)
        Process.run(dart, [
          '--packages=.dart_tool/package_config.json',
          'test/support/open_main.dart',
          cache.path,
          commit,
          '${start.millisecondsSinceEpoch}',
        ]),
    ]);

    for (final result in results) {
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    final store = BaselineStore.open(cache.path, fakeKey());
    for (final commit in commits) {
      expect(
        store
            .at(commit, 'root')
            .baseline('test/goldens/a.png')
            ?.readAsStringSync(),
        'rendered at $commit',
      );
    }
    expect(
      MachineKey.fromJson(
        jsonDecode(
          File('${store.machineDir.path}/manifest.json').readAsStringSync(),
        ) as Map<String, Object?>,
      ),
      fakeKey(),
    );
  });
}
