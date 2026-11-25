import 'dart:io';

/// The `flutter test` run this process belongs to, or null where it cannot
/// be told.
///
/// `flutter test` runs each test file in a process of its own, all children
/// of the one tool process (measured), so the run is the parent's pid and
/// start time; the start time tells a reused pid apart.
String? currentRun() => ProcessTable.current.runOf(pid);

/// Runs a process to its end, as `Process.runSync` does.
typedef SyncProcessRunner = ProcessResult Function(
  String executable,
  List<String> arguments,
);

/// What the OS can say about a process's parent.
sealed class ProcessTable {
  const new(SyncProcessRunner run) : _run = run;

  /// The table of the OS this runs on.
  static ProcessTable get current =>
      Platform.isWindows ? const CimProcessTable() : const PsProcessTable();

  final SyncProcessRunner _run;

  /// The run of process [child]: its parent's pid and start time, or null
  /// when either cannot be read. Never throws.
  String? runOf(int child) {
    try {
      return _runOf(child);
    } on ProcessException {
      return null;
    }
  }

  String? _runOf(int child);

  // The trimmed output of a run that succeeded; empty otherwise.
  String _ask(String executable, List<String> arguments) {
    final result = _run(executable, arguments);
    return result.exitCode == 0 ? '${result.stdout}'.trim() : '';
  }
}

/// macOS and Linux: two questions to `ps`.
final class PsProcessTable extends ProcessTable {
  /// A table read with [run].
  const new([super.run = Process.runSync]);

  @override
  String? _runOf(int child) {
    final parent = _ask('ps', ['-o', 'ppid=', '-p', '$child']);
    if (parent.isEmpty) return null;
    final started = _ask('ps', ['-o', 'lstart=', '-p', parent]);
    return started.isEmpty ? null : '$parent $started';
  }
}

/// Windows, which has no `ps`: one PowerShell question to `Win32_Process`.
///
/// A PowerShell start costs a few hundred milliseconds, once per test file
/// that records a golden. That is the price of a report that is swept per
/// run, rather than one that keeps every stale entry.
final class CimProcessTable extends ProcessTable {
  /// A table read with [run].
  const new([super.run = Process.runSync]);

  // A pid, a space and a UTC ISO 8601 time, as the script below prints them.
  static final _answer = RegExp(r'^\d+ \d{4}-\d\d-\d\dT\S+Z$');

  /// The PowerShell script that prints [child]'s parent's pid and creation
  /// time, or nothing when either process is gone.
  static String script(int child) => _script.replaceAll('{child}', '$child');

  static const _script =
      r'$c = Get-CimInstance Win32_Process -Filter "ProcessId={child}"; '
      r'if ($c) { $p = Get-CimInstance Win32_Process -Filter '
      r'"ProcessId=$($c.ParentProcessId)"; '
      r'if ($p) { "$($p.ProcessId) '
      r'''$($p.CreationDate.ToUniversalTime().ToString('o'))" } }''';

  @override
  String? _runOf(int child) {
    final answer = _ask('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script(child),
    ]);
    return _answer.hasMatch(answer) ? answer : null;
  }
}
