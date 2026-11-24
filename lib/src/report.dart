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
    this.run,
  });

  /// An entry as [toJson] wrote it.
  factory ReportEntry.fromJson(Map<String, Object?> json) => ReportEntry(
    golden: json['golden'] as String,
    outcome: GoldenOutcome.values.byName(json['outcome'] as String),
    baseline: json['baseline'] as String,
    diffs: [for (final path in json['diffs'] as List<Object?>) path as String],
    at: DateTime.parse(json['at'] as String),
    run: json['run'] as String?,
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

  /// The test run that recorded it; see [GoldenReport.run].
  final String? run;

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

/// The outcomes of the last test run, per checkout: every golden that failed
/// or was changed.
///
/// In the package's `.dart_tool/portable_goldens/report/`: per checkout, since
/// each worktree's run says something about its own branch, and never
/// committed, since `.dart_tool/` is the tool's own.
///
/// The first write of a test process deletes every entry an earlier run
/// left, so a golden fixed or deleted since is not listed. A run that compares
/// no golden at all leaves the last run's entries.
class GoldenReport {
  /// The report of the package at [packageDir], written by the test run
  /// [run] names; by default, [currentRun].
  GoldenReport(String packageDir, {String? Function()? run})
    : dir = Directory('$packageDir/.dart_tool/portable_goldens/report'),
      _run = run ?? currentRun;

  /// Where the entries are.
  final Directory dir;

  final String? Function() _run;

  /// The `flutter test` run this process belongs to, or null where it cannot
  /// be told.
  ///
  /// `flutter test` runs each test file in a process of its own, all
  /// children of the one tool process (measured), so the run is the parent's
  /// pid and start time; the start time tells a reused pid apart. Asked of
  /// `ps`, once per process and only when an entry is written. Windows has no
  /// `ps`: there, entries are never swept, only replaced.
  late final String? run = _run();

  bool _swept = false;

  File _file(String golden) =>
      File('${dir.path}/${golden.replaceAll('/', '__')}.json');

  /// Records [entry], replacing the golden's last one.
  void record(ReportEntry entry) {
    _sweep();
    dir.createSync(recursive: true);
    final json = ReportEntry(
      golden: entry.golden,
      outcome: entry.outcome,
      baseline: entry.baseline,
      diffs: entry.diffs,
      at: entry.at,
      run: run,
    ).toJson();
    // Renamed into place, so a sweep in another process of this run never
    // reads half of it and takes it for an earlier run's.
    final file = _file(entry.golden);
    final temp = File('${file.path}.$pid.tmp')
      ..writeAsStringSync(jsonEncode(json));
    temp.renameSync(file.path);
  }

  /// Forgets [golden]: it passed, and this branch did not change it.
  void clear(String golden) {
    _sweep();
    final file = _file(golden);
    if (file.existsSync()) file.deleteSync();
  }

  void _sweep() {
    if (_swept) return;
    _swept = true;
    final current = run;
    if (current == null || !dir.existsSync()) return;
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        if (json['run'] == current) continue;
      } on Object {
        // Half written by a killed run: as stale as any other.
      }
      try {
        file.deleteSync();
      } on FileSystemException {
        // Another process of this run swept it first.
      }
    }
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

/// The test run of this process, as [GoldenReport.run] describes it.
String? currentRun() {
  if (Platform.isWindows) return null;
  String ask(List<String> args) {
    final result = Process.runSync('ps', args);
    return result.exitCode == 0 ? '${result.stdout}'.trim() : '';
  }

  try {
    final parent = ask(['-o', 'ppid=', '-p', '$pid']);
    if (parent.isEmpty) return null;
    final started = ask(['-o', 'lstart=', '-p', parent]);
    return started.isEmpty ? null : '$parent $started';
  } on ProcessException {
    return null;
  }
}
