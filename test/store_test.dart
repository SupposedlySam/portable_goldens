import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:machine_goldens/baselines.dart';

import 'support/repo.dart';

void main() {
  late Directory cache;

  setUp(() => cache = Directory.systemTemp.createTempSync('machine_goldens_store'));
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
    File('${store.unitDir('c0ffee', 'root').path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('half written');

    expect(store.isComplete('c0ffee', 'root'), isFalse);
    expect(store.baseline('c0ffee', 'root', 'test/goldens/a.png'), isNull);

    var builds = 0;
    await store.fill('c0ffee', 'root', (into) {
      builds++;
      return render(into);
    });

    expect(builds, 1);
    expect(
      store.baseline('c0ffee', 'root', 'test/goldens/a.png')!.readAsStringSync(),
      'rendered',
    );
  });

  test('a complete baseline is not built again', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    await store.fill('c0ffee', 'root', render);

    var builds = 0;
    await store.fill('c0ffee', 'root', (into) {
      builds++;
      return render(into);
    });

    expect(builds, 0);
  });

  test('nothing is readable while a build is still writing', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    final writing = Completer<void>();
    final finish = Completer<void>();
    final fill = store.fill('c0ffee', 'root', (into) async {
      final built = await render(into);
      writing.complete();
      await finish.future;
      return built;
    });

    await writing.future;
    expect(store.baseline('c0ffee', 'root', 'test/goldens/a.png'), isNull);
    finish.complete();
    await fill;
    expect(store.baseline('c0ffee', 'root', 'test/goldens/a.png'), isNotNull);
  });

  test('a manifest that disagrees with the key throws the folder away', () {
    final key = fakeKey();
    final dir = Directory('${cache.path}/${key.id}');
    File('${dir.path}/manifest.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"os":"macos","osVersion":"Version 26.6.2 (Build 25G83)",'
        '"arch":"macos_arm64","engineRevision":"x","dartVersion":"3.13.4"}',
      );
    File('${dir.path}/c0ffee/root/.complete').createSync(recursive: true);

    final store = BaselineStore.open(cache.path, key);

    expect(store.isComplete('c0ffee', 'root'), isFalse);
    expect(File('${dir.path}/manifest.json').readAsStringSync(),
        contains('26B131'));
  });

  test('an unreadable manifest is rewritten, and the baselines beside it are '
      'kept', () async {
    final key = fakeKey();
    await BaselineStore.open(cache.path, key).fill('c0ffee', 'root', render);
    // Half of one, as a reader saw it mid-write before writes were atomic.
    File('${cache.path}/${key.id}/manifest.json').writeAsStringSync('{"os":');

    final store = BaselineStore.open(cache.path, key);

    expect(store.baseline('c0ffee', 'root', 'test/goldens/a.png'), isNotNull);
    expect(
      File('${cache.path}/${key.id}/manifest.json').readAsStringSync(),
      contains('26B131'),
    );
  });

  test('an image the marker does not list is not a baseline, nor is any '
      'image under a marker that does not parse', () async {
    final store = BaselineStore.open(cache.path, fakeKey());
    await store.fill('c0ffee', 'root', render);
    final dir = store.unitDir('c0ffee', 'root').path;
    File('$dir/test/goldens/b.png').writeAsStringSync('copied in by hand');

    expect(store.baseline('c0ffee', 'root', 'test/goldens/b.png'), isNull);

    File('$dir/.complete').writeAsStringSync('{"files": [');
    expect(store.isComplete('c0ffee', 'root'), isFalse);
    expect(store.baseline('c0ffee', 'root', 'test/goldens/a.png'), isNull);
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

    await store.fill('c0ffee', 'root', render);

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

    final first = store.fill('c0ffee', 'root', failing);
    await started.future;
    final second = store.fill('c0ffee', 'root', failing);

    await expectLater(first, throwsA(isA<BuildFailure>()));
    await expectLater(
      second,
      throwsA(isA<BuildFailure>().having((f) => f.message, 'message', 'exited 1')),
    );
    expect(builds, 1);
  });

  test('two processes filling the same baseline at once build it once',
      () async {
    final dart = '${MachineKey.flutterRoot()}/bin/cache/dart-sdk/bin/dart';
    final log = File('${cache.path}/builds.log');
    Future<ProcessResult> one() => Process.run(dart, [
      '--packages=.dart_tool/package_config.json',
      'test/support/fill_main.dart',
      cache.path,
      log.path,
    ]);

    final results = await Future.wait([one(), one()]);

    for (final result in results) {
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    final builders = log.readAsLinesSync();
    expect(builders, hasLength(1));
    expect(
      [for (final r in results) (r.stdout as String).trim()],
      everyElement('rendered by ${builders.single}'),
    );
  });
}
