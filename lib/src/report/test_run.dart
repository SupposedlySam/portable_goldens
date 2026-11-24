import 'dart:io';

/// The `flutter test` run this process belongs to, or null where it cannot
/// be told.
///
/// `flutter test` runs each test file in a process of its own, all children
/// of the one tool process (measured), so the run is the parent's pid and
/// start time; the start time tells a reused pid apart. Asked of `ps`.
/// Windows has no `ps`: there it is null.
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
