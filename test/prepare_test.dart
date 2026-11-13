import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:machine_goldens/baselines.dart';
import 'package:machine_goldens/src/prepare.dart';

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

  Future<(int, String, String)> run(FakeFlutter flutter) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await prepare(
      MachineGoldens(
        packageDir: repo.dir,
        environment: const {'FLUTTER_ROOT': '/fake/flutter'},
        key: fakeKey(),
        cacheRoot: cache.path,
        runProcess: flutter.call,
      ),
      '**/goldens/**/*.png',
      out: out,
      err: err,
    );
    return (code, '$out', '$err');
  }

  test(
    'builds what is missing, then says every baseline is in place',
    () async {
      final (code, out, err) = await run(FakeFlutter());

      expect(code, 0, reason: err);
      expect(out, contains('2 goldens: every baseline is in place.'));
    },
  );

  test('a build that passed without writing a golden is a failure, not '
      '"in place"', () async {
    final (code, out, err) = await run(
      FakeFlutter(renders: ['test/goldens/a.png']),
    );

    expect(code, 1);
    expect(err, contains('passed but did not write test/goldens/b.png'));
    expect(out, isNot(contains('every baseline is in place')));
    expect(out, contains('1 golden not written by a build that passed.'));
  });
}
