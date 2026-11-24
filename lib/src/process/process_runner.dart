import 'dart:convert';
import 'dart:io';

/// `Process.run`, or a stand-in for it in tests.
///
/// The one way this package starts a process, for `git` and `flutter` alike,
/// so a test that fakes one fakes the other the same way. `Process.run` is
/// one, as a constant tear-off. A null [stdoutEncoding] keeps stdout as bytes,
/// as `git show` of an image needs.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment,
  Encoding? stdoutEncoding,
});

/// The last [lines] lines of a process's [output], for a failure message.
String tailOf(String output, {int lines = 40}) {
  final all = output.trim().split('\n');
  return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
}
