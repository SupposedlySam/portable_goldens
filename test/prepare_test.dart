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

  Future<(int, String, String)> run(FakeFlutter flutter) async {
    final out = StringBuffer();
    final err = StringBuffer();
    const environment = {'FLUTTER_ROOT': '/fake/flutter'};
    final code = await runPortableGoldens(
      'prepare',
      const [],
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
          runProcess: flutter.call,
        ),
      ),
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

  test('a configuration it cannot read exits 1, naming it, and builds '
      'nothing', () async {
    repo.write('pubspec.yaml', 'portable_goldens:\n  setup: make gen\n');
    final flutter = FakeFlutter();

    final (code, out, err) = await run(flutter);

    expect(code, 1);
    expect(
      err,
      'prepare: portable_goldens cannot read its configuration in '
      '${repo.dir}/pubspec.yaml: `portable_goldens.setup` is not a list of '
      'command lines.\n',
    );
    expect(flutter.sequence, isEmpty);
  });
}
