/// How a golden came out of its last comparison.
enum GoldenOutcome {
  /// It did not match this machine's baseline: the test failed.
  failed,

  /// It passed, and this branch changed it: listed with its diff against
  /// what it was before the branch.
  changed,
}

/// One golden's last comparison, as the `report` command lists it.
final class ReportEntry {
  /// [golden] (package-relative) came out [outcome] against [baseline].
  const new({
    required this.golden,
    required this.outcome,
    required this.baseline,
    required this.diffs,
    required this.at,
    this.run,
  });

  /// An entry as [toJson] wrote it; throws [FormatException] when it is not
  /// one.
  factory fromJson(Map<String, Object?> json) {
    if (json case {
      'golden': final String golden,
      'outcome': final String outcome,
      'baseline': final String baseline,
      'diffs': final List<Object?> diffs,
      'at': final String at,
    }) {
      return ReportEntry(
        golden: golden,
        outcome: GoldenOutcome.values.byName(outcome),
        baseline: baseline,
        diffs: diffs.cast<String>().toList(),
        at: DateTime.parse(at),
        run: json['run'] as String?,
      );
    }
    throw FormatException('Not a report entry', json);
  }

  /// The golden's path in its package.
  final String golden;

  /// How it came out.
  final GoldenOutcome outcome;

  /// What it was compared with, in words.
  final String baseline;

  /// The diff images Flutter wrote, absolute; empty when the render matched
  /// the image it was compared with.
  final List<String> diffs;

  /// When.
  final DateTime at;

  /// The test run that recorded it; see `GoldenReport.run`.
  final String? run;

  /// This entry, recorded by [run].
  ReportEntry inRun(String? run) => ReportEntry(
    golden: golden,
    outcome: outcome,
    baseline: baseline,
    diffs: diffs,
    at: at,
    run: run,
  );

  /// The entry as JSON.
  Map<String, Object> toJson() => {
    'golden': golden,
    'outcome': outcome.name,
    'baseline': baseline,
    'diffs': diffs,
    'at': at.toIso8601String(),
    'run': ?run,
  };
}
