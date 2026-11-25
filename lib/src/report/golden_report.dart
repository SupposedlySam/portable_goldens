import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/report/report_entry.dart';
import 'package:portable_goldens/src/report/test_run.dart';
import 'package:portable_goldens/src/store/atomic_file.dart';

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
final class GoldenReport {
  /// The report of the package at [packageDir], written by the test run
  /// [run] names; by default, [currentRun].
  new(String packageDir, {String? Function()? run})
    : dir = Directory('$packageDir/.dart_tool/portable_goldens/report'),
      _run = run ?? currentRun;

  /// Where the entries are.
  final Directory dir;

  final String? Function() _run;

  /// The test run that writes here, asked once per process and only when an
  /// entry is written. Where it is null (the OS's process table would not
  /// answer), entries are never swept, only replaced.
  late final String? run = _run();

  bool _swept = false;

  File _file(String golden) =>
      File('${dir.path}/${golden.replaceAll('/', '__')}.json');

  /// Records [entry], replacing the golden's last one.
  ///
  /// Renamed into place, so a sweep in another process of this run never
  /// reads half of it and takes it for an earlier run's.
  void record(ReportEntry entry) {
    _sweep();
    dir.createSync(recursive: true);
    writeAtomically(_file(entry.golden), jsonEncode(entry.inRun(run).toJson()));
  }

  /// Forgets [golden]: it passed, and this branch did not change it.
  void clear(String golden) {
    _sweep();
    final file = _file(golden);
    if (file.existsSync()) file.deleteSync();
  }

  /// Every entry, by golden. A half-written entry from a killed run is left
  /// out: the next run rewrites it.
  List<ReportEntry> read() =>
      [for (final file in _entryFiles()) ?_entryIn(file)]
        ..sort((a, b) => a.golden.compareTo(b.golden));

  void _sweep() {
    if (_swept) return;
    _swept = true;
    final current = run;
    if (current == null) return;
    for (final file in _entryFiles()) {
      // An entry that does not parse is as stale as any other.
      if (_entryIn(file)?.run == current) continue;
      try {
        file.deleteSync();
      } on FileSystemException {
        // Another process of this run swept it first.
      }
    }
  }

  Iterable<File> _entryFiles() => dir.existsSync()
      ? dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))
      : const [];

  static ReportEntry? _entryIn(File file) {
    try {
      if (jsonDecode(file.readAsStringSync())
          case final Map<String, Object?> json) {
        return ReportEntry.fromJson(json);
      }
    } on Object {
      // Missing, half written, or not an entry.
    }
    return null;
  }
}
