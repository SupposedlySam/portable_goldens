import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'report.dart';
import 'session.dart';
import 'store.dart';

/// Compares each golden exactly against this machine's baseline: the image
/// the commit that last changed the golden renders on this machine.
///
/// Install it from `test/flutter_test_config.dart`:
///
/// ```dart
/// Future<void> testExecutable(FutureOr<void> Function() testMain) async {
///   MachineGoldenComparator.install();
///   await testMain();
/// }
/// ```
///
/// The pixel comparison is `GoldenFileComparator.compareLists`, which passes
/// only when every pixel is equal: there is no tolerance. `--update-goldens`
/// writes the committed pngs, as `LocalFileComparator` does.
class MachineGoldenComparator extends LocalFileComparator {
  /// A comparator for the test file at [testFile], resolving baselines with
  /// [goldens] and recording outcomes in [report].
  MachineGoldenComparator(
    super.testFile, {
    required this.goldens,
    required this.report,
  });

  /// Replaces the `LocalFileComparator` `flutter test` installed for this
  /// test file with one that compares against machine baselines.
  ///
  /// [packageDir] is the package under test, by default the current folder,
  /// which `flutter test` sets to the package's root. Every test file in the
  /// process shares one [MachineGoldens], so git is asked once.
  static void install({String? packageDir}) {
    final current = goldenFileComparator;
    if (current is! LocalFileComparator) return;
    final dir = packageDir ?? Directory.current.path;
    final goldens = _shared[dir] ??= MachineGoldens(packageDir: dir);
    goldenFileComparator = MachineGoldenComparator(
      current.basedir.resolve('machine_goldens.dart'),
      goldens: goldens,
      report: GoldenReport(dir),
    );
  }

  static final _shared = <String, MachineGoldens>{};
  static final _told = <String>{};

  /// Resolves each golden's baseline.
  final MachineGoldens goldens;

  /// Where outcomes are recorded for the `report` command.
  final GoldenReport report;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final path = _goldenPath(golden);
    final GoldenBaseline baseline;
    try {
      baseline = await goldens.baselineFor(path);
    } on BuildFailure catch (failure) {
      // Never a pass: a golden that could not be checked is not a match.
      throw FlutterError('Golden "$golden": $failure');
    }
    final inPackage = _inPackage(path);
    final (List<int> expected, String against) = switch (baseline) {
      CommittedBaseline(:final reason) => (
        await _committed(golden, reason),
        'the committed image, because $reason',
      ),
      WorkingTreeBaseline() => (
        await getGoldenBytes(golden),
        'the png in the working tree, which differs from HEAD',
      ),
      MachineBaseline(:final file, :final commit, :final keyId) => (
        await file.readAsBytes(),
        "this machine's baseline, rendered from commit ${_short(commit)} "
            '(machine $keyId): ${file.path}',
      ),
    };
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      expected,
    );
    if (!result.passed) {
      // Every kind of baseline records its failure, so `report` lists a
      // golden that failed against the committed image too.
      final error = await generateFailureOutput(result, golden, basedir);
      final diffs = _failureFiles(result, golden, '');
      result.dispose();
      report.record(ReportEntry(
        golden: inPackage,
        outcome: GoldenOutcome.failed,
        baseline: against,
        diffs: diffs,
        at: DateTime.now(),
      ));
      throw FlutterError('$error\nCompared exactly against $against');
    }
    result.dispose();
    await _passed(imageBytes, golden, path, inPackage);
    return true;
  }

  Future<List<int>> _committed(Uri golden, String reason) {
    if (_told.add(reason) && !reason.contains('itself building')) {
      stderr.writeln('machine_goldens: comparing with the committed '
          'images, because $reason.');
    }
    return getGoldenBytes(golden);
  }

  /// A golden that passed is listed when this branch changed it, with its
  /// diff against what it was before the branch: information for a review,
  /// never a verdict, since the compare that decides the test already ran.
  Future<void> _passed(
    Uint8List imageBytes,
    Uri golden,
    String path,
    String inPackage,
  ) async {
    final change = await goldens.branchChange(path);
    if (change == null) {
      report.clear(inPackage);
      return;
    }
    final diffs = <String>[];
    final before = change.image;
    if (before != null) {
      final result = await GoldenFileComparator.compareLists(imageBytes, before);
      if (!result.passed) {
        await generateFailureOutput(result, golden, basedir, key: 'branch');
        diffs.addAll(_failureFiles(result, golden, 'branch'));
      }
      result.dispose();
    }
    report.record(ReportEntry(
      golden: inPackage,
      outcome: GoldenOutcome.changed,
      baseline: 'changed by this branch since ${_short(change.base)}; '
          'compared with ${change.was}',
      diffs: diffs,
      at: DateTime.now(),
    ));
  }

  String _goldenPath(Uri golden) =>
      File.fromUri(basedir.resolveUri(Uri(path: golden.path))).path;

  String _inPackage(String path) {
    final dir = goldens.packageDir;
    return path.startsWith('$dir/') ? path.substring(dir.length + 1) : path;
  }

  List<String> _failureFiles(ComparisonResult result, Uri golden, String key) => [
    for (final name in result.diffs?.keys ?? const <String>[])
      getFailureFile(key.isEmpty ? name : '${name}_$key', golden, basedir).path,
  ];
}

String _short(String sha) => sha.length > 10 ? sha.substring(0, 10) : sha;

