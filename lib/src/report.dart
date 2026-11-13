import 'dart:convert';
import 'dart:io';

/// How a golden came out of its last comparison.
enum GoldenOutcome {
  /// It did not match this machine's baseline: the test failed.
  failed,

  /// It passed, and this branch changed it: listed with its diff against
  /// what it was before the branch.
  changed,
}

/// One golden's last comparison, as the `report` command lists it.
class ReportEntry {
  /// [golden] (package-relative) came out [outcome] against [baseline].
  const ReportEntry({
    required this.golden,
    required this.outcome,
    required this.baseline,
    required this.diffs,
    required this.at,
  });

  /// An entry as [toJson] wrote it.
  factory ReportEntry.fromJson(Map<String, Object?> json) => ReportEntry(
    golden: json['golden'] as String,
    outcome: GoldenOutcome.values.byName(json['outcome'] as String),
    baseline: json['baseline'] as String,
    diffs: [for (final path in json['diffs'] as List<Object?>) path as String],
    at: DateTime.parse(json['at'] as String),
  );

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

  /// The entry as JSON.
  Map<String, Object> toJson() => {
    'golden': golden,
    'outcome': outcome.name,
    'baseline': baseline,
    'diffs': diffs,
    'at': at.toIso8601String(),
  };
}

/// The last outcome of every golden that failed or was changed, per checkout.
///
/// In the package's `.dart_tool/machine_goldens/report/`: per checkout, since
/// each worktree's run says something about its own branch, and never
/// committed, since `.dart_tool/` is the tool's own.
class GoldenReport {
  /// The report of the package at [packageDir].
  GoldenReport(String packageDir)
    : dir = Directory('$packageDir/.dart_tool/machine_goldens/report');

  /// Where the entries are.
  final Directory dir;

  File _file(String golden) =>
      File('${dir.path}/${golden.replaceAll('/', '__')}.json');

  /// Records [entry], replacing the golden's last one.
  void record(ReportEntry entry) {
    dir.createSync(recursive: true);
    _file(entry.golden).writeAsStringSync(jsonEncode(entry.toJson()));
  }

  /// Forgets [golden]: it passed, and this branch did not change it.
  void clear(String golden) {
    final file = _file(golden);
    if (file.existsSync()) file.deleteSync();
  }

  /// Every entry, by golden.
  List<ReportEntry> read() {
    if (!dir.existsSync()) return const [];
    final entries = <ReportEntry>[];
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      try {
        entries.add(
          ReportEntry.fromJson(
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
          ),
        );
      } on Object {
        // A half-written entry from a killed run: the next run rewrites it.
      }
    }
    return entries..sort((a, b) => a.golden.compareTo(b.golden));
  }
}
