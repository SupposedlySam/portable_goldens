import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/command_runner.dart';
import 'package:portable_goldens/src/cli/commands/verify_command.dart';

import 'support/repo.dart';

/// A pixel compare that answers [verdict] for each pair, and records them.
class FakePixels implements PixelComparer {
  new({this.verdict, this.fails = false});

  /// The answer for a pair; "different" with one diff image when null.
  final PixelVerdict Function(ImagePair pair)? verdict;

  /// Whether the compare fails, as a run that could not start does.
  final bool fails;

  /// Every pair it was asked about, with its images' bytes at the time.
  final asked = <({ImagePair pair, String committed, String rendered})>[];

  @override
  Future<List<PixelVerdict>> compare(List<ImagePair> pairs) async {
    for (final pair in pairs) {
      asked.add((
        pair: pair,
        committed: File(pair.committed).readAsStringSync(),
        rendered: File(pair.rendered).readAsStringSync(),
      ));
    }
    if (fails) throw const PixelCompareFailure('flutter test exited 1');
    return [
      for (final pair in pairs)
        verdict?.call(pair) ??
            PixelVerdict.different(
              'Pixel test failed, 1.00%, 4px diff '
              'detected.',
              ['${pair.diffDir}/isolatedDiff.png'],
            ),
    ];
  }
}

// Draws the png each fixture commits: 'committed a' for a.png.
List<int> drawsWhatIsCommitted(String golden, String commit) =>
    'committed ${golden.split('/').last[0]}'.codeUnits;

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

  Future<(int, String, String)> verify(
    List<String> args, {
    FakeFlutter? flutter,
    FakePixels? pixels,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    const environment = {'FLUTTER_ROOT': '/fake/flutter'};
    final code = await runPortableGoldens(
      'verify',
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
          runProcess: (flutter ?? FakeFlutter()).call,
        ),
        pixels: () => pixels ?? FakePixels(),
      ),
    );
    return (code, '$out', '$err');
  }

  String mismatchDir(String golden) =>
      '${repo.dir}/${VerifyCommand.mismatchDir}/$golden';

  test(
    'a png its own commit draws verifies, without a pixel compare',
    () async {
      final pixels = FakePixels();

      final (code, out, err) = await verify(
        ['--all'],
        flutter: FakeFlutter(draw: drawsWhatIsCommitted),
        pixels: pixels,
      );

      expect(code, 0, reason: err);
      expect(out, contains('Verifying 2 goldens tracked, on machine '));
      expect(out, contains('  verified      test/goldens/a.png ('));
      expect(out, contains('  verified      test/goldens/b.png ('));
      expect(out, contains('\n2 verified.\n'));
      expect(out, contains('only matches its render on the machine'));
      expect(pixels.asked, isEmpty);
    },
  );

  test('a png its commit cannot draw is a mismatch, with both images, the '
      'diff and the likely cause', () async {
    final pixels = FakePixels();

    final (code, out, err) = await verify(['--all'], pixels: pixels);

    expect(code, 1, reason: err);
    final dir = mismatchDir('test/goldens/a.png');
    expect(out, contains('  MISMATCH      test/goldens/a.png ('));
    expect(
      out,
      contains(
        '): Pixel test failed, 1.00%, 4px diff detected.\n'
        '    committed   $dir/committed.png\n'
        '    rendered    $dir/rendered.png\n'
        '    diff        $dir/isolatedDiff.png\n',
      ),
    );
    expect(
      out,
      contains(
        'cannot draw its own png: was it committed before '
        'its code, or with part of it (git add -p, a split rebase)?',
      ),
    );
    expect(out, contains('\n2 mismatches.\n'));
    // The compare saw the committed png and this machine's render of it.
    expect(pixels.asked.map((a) => a.committed), [
      'committed a',
      'committed b',
    ]);
    expect(
      pixels.asked.first.rendered,
      startsWith('rendered test/goldens/a.png at '),
    );
    expect(File('$dir/committed.png').readAsStringSync(), 'committed a');
  });

  test(
    'different bytes with the same pixels verify: another encoder',
    () async {
      final (code, out, err) = await verify([
        '--all',
      ], pixels: FakePixels(verdict: (_) => const PixelVerdict.same()));

      expect(code, 0, reason: err);
      expect(out, contains('\n2 verified.\n'));
      expect(Directory(mismatchDir('test/goldens/a.png')).existsSync(), isTrue);
    },
  );

  test("a mismatch's folder holds only this run's images", () async {
    final stale = File('${mismatchDir('test/goldens/a.png')}/old_diff.png')
      ..createSync(recursive: true);

    await verify(['--all']);

    expect(stale.existsSync(), isFalse);
    expect(
      File('${mismatchDir('test/goldens/a.png')}/rendered.png').existsSync(),
      isTrue,
    );
  });

  test('a png changed in the working tree is checked as HEAD has it', () async {
    repo.write('test/goldens/a.png', 'a, edited and not committed');

    final (code, out, err) = await verify([
      '--all',
    ], flutter: FakeFlutter(draw: drawsWhatIsCommitted));

    expect(code, 0, reason: err);
    expect(out, contains('  verified      test/goldens/a.png ('));
    expect(out, contains('\n2 verified.\n'));
  });

  group('without --all', () {
    test('checks only what the branch changed; a new png is uncommitted, not '
        'a failure', () async {
      await repo.git(['checkout', '--quiet', '-b', 'feature']);
      repo
        ..write('test/goldens/a.png', 'a, as the branch draws it')
        ..write('test/a_test.dart', '// draws a with matchesGoldenFile\n');
      await repo.commit('change a');
      repo.write('test/goldens/c.png', 'c, new');

      final (code, out, err) = await verify(
        const [],
        flutter: FakeFlutter(
          draw: (golden, commit) => golden.endsWith('a.png')
              ? 'a, as the branch draws it'.codeUnits
              : drawsWhatIsCommitted(golden, commit),
        ),
      );

      expect(code, 0, reason: err);
      expect(out, contains('Verifying 2 goldens changed by this branch'));
      expect(out, contains('  verified      test/goldens/a.png ('));
      expect(out, contains('  uncommitted   test/goldens/c.png: no commit '));
      expect(out, isNot(contains('b.png')));
      expect(out, contains('\n1 verified, 1 uncommitted.\n'));
    });

    test('with nothing changed, says so and how to check everything', () async {
      final (code, out, err) = await verify(const []);

      expect(code, 0, reason: err);
      expect(
        out,
        'No golden changed by this branch; `--all` verifies every golden.\n',
      );
    });
  });

  test('a commit that does not build is unbuilt, a failure', () async {
    final (code, out, _) = await verify([
      '--all',
    ], flutter: FakeFlutter(testExitCode: 1));

    expect(code, 1);
    expect(out, contains('  UNBUILT       test/goldens/a.png\n'));
    expect(out, contains('\n2 unbuilt.\n'));
  });

  test(
    'a pixel compare that fails leaves each pair not checked, a failure',
    () async {
      final (code, out, _) = await verify([
        '--all',
      ], pixels: FakePixels(fails: true));

      expect(code, 1);
      expect(
        out,
        contains(
          '  NOT CHECKED   test/goldens/a.png: the pixel compare '
          'failed: ',
        ),
      );
      expect(out, contains('flutter test exited 1'));
      expect(out, contains('\n2 not checked.\n'));
    },
  );

  test(
    'where machine baselines do not apply, it cannot verify: exit 1',
    () async {
      Directory('${repo.dir}/.git').deleteSync(recursive: true);

      final (code, out, err) = await verify(['--all']);

      expect(code, 1);
      expect(out, isEmpty);
      expect(
        err,
        'Cannot verify: machine baselines are not used here, because the '
        'package is not in a git repository.\n',
      );
    },
  );

  test('--json writes every check, and whether verify passed', () async {
    final (code, out, err) = await verify([
      '--all',
      '--json',
    ], flutter: FakeFlutter(draw: drawsWhatIsCommitted));

    expect(code, 0, reason: err);
    final json = jsonDecode(out) as Map<String, Object?>;
    expect(json['machine'], fakeKey().id);
    expect(json['passed'], isTrue);
    final checks = json['checks']! as List<Object?>;
    expect(checks, hasLength(2));
    expect(checks.first, {
      'golden': 'test/goldens/a.png',
      'result': 'verified',
      'commit': await repo.git(['rev-parse', 'HEAD']),
    });
  });
}
