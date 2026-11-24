import 'package:portable_goldens/src/report/report_entry.dart';

/// A golden this branch changed, and what its last test run said of it.
final class ChangedGolden {
  /// The golden at [golden], with [entry] its last recorded comparison.
  const new(this.golden, {this.entry});

  /// The package-relative path of the png.
  final String golden;

  /// What its last test run recorded, or null when none did.
  final ReportEntry? entry;

  /// Whether a test run compared it as a branch change; until one does there
  /// is no diff to show.
  bool get isCompared => entry?.outcome == GoldenOutcome.changed;

  /// The json `report --json` writes for it.
  Map<String, Object?> toJson() => {
    'golden': golden,
    'compared': isCompared,
    if (isCompared) 'baseline': entry?.baseline,
    'diffs': isCompared ? entry?.diffs ?? const <String>[] : const <String>[],
  };
}

/// What the work on a branch did to its goldens: the ones that failed
/// against this machine's baseline, and the ones the branch changed.
final class WorkSummary {
  /// The summary of [entries], the recorded comparisons, for the goldens
  /// [changedByBranch] since [base]; [exists] says whether a golden's png is
  /// still on disk.
  factory of({
    required Iterable<ReportEntry> entries,
    required List<String> changedByBranch,
    required String? base,
    required bool Function(String golden) exists,
  }) {
    final byGolden = {for (final entry in entries) entry.golden: entry};
    return WorkSummary._(
      base: base,
      // A failure whose png is gone was deleted since, so it is not one now.
      failed: [
        for (final entry in byGolden.values)
          if (entry.outcome == GoldenOutcome.failed && exists(entry.golden))
            entry,
      ],
      changed: [
        for (final golden in changedByBranch)
          ChangedGolden(golden, entry: byGolden[golden]),
      ],
    );
  }

  new _({required this.base, required this.failed, required this.changed});

  /// The commit the branch is measured from, or null when machine baselines
  /// are not used.
  final String? base;

  /// The goldens whose last comparison failed.
  final List<ReportEntry> failed;

  /// The goldens this branch changed.
  final List<ChangedGolden> changed;

  /// The json `report --json` writes.
  Map<String, Object?> toJson() => {
    'base': base,
    'failed': [
      for (final entry in failed)
        {'golden': entry.golden, 'diffs': entry.diffs},
    ],
    'changed': [for (final golden in changed) golden.toJson()],
  };
}
