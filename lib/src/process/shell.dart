import 'dart:io';

import 'package:portable_goldens/src/process/process_runner.dart';

/// The shell a command line from the user's configuration runs in, and how
/// its `PATH` is written.
///
/// A setup step is a command line, as in a CI `run:` or a melos script, so it
/// runs the way a developer would type it: quoting, `&&` and variables
/// included. Splitting it into arguments here would be a second, weaker shell.
enum Shell {
  /// `/bin/sh -c <command line>`, with `:` between `PATH` entries.
  posix,

  /// `cmd.exe /d /c <batch file>`, the command line its one line, with `;`
  /// between `PATH` entries. `/d` skips the user's AutoRun commands, so a
  /// build does not depend on them.
  ///
  /// Not `cmd.exe /d /s /c <command line>`: Dart quotes a Windows argument
  /// the way C programs parse one, writing each `"` as `\"`, and cmd reads
  /// no backslash escapes. A step with a double quote in it, such as
  /// `set "PATH=..."`, reached cmd mangled and did something else (CI,
  /// 2026-11-25). cmd reads a batch file's lines as written. The cost is
  /// batch syntax: a literal `%` is written `%%`, and `%1` is an argument.
  windows;

  /// The shell of the OS this runs on.
  static Shell get current => Platform.isWindows ? windows : posix;

  /// The executable that runs a command line.
  String get executable => switch (this) {
    posix => '/bin/sh',
    windows => 'cmd.exe',
  };

  /// Runs [commandLine] with [runner] in [workingDirectory], with exactly
  /// [environment].
  Future<ProcessResult> run(
    String commandLine, {
    required ProcessRunner runner,
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    Future<ProcessResult> start(List<String> arguments) => runner(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
    );
    switch (this) {
      case posix:
        return await start(['-c', commandLine]);
      case windows:
        final dir = Directory.systemTemp.createTempSync('portable_goldens_');
        try {
          final script = File('${dir.path}${Platform.pathSeparator}step.cmd')
            ..writeAsStringSync('@echo off\r\n$commandLine\r\n');
          return await start(['/d', '/c', script.path]);
        } finally {
          dir.deleteSync(recursive: true);
        }
    }
  }

  /// The command line that puts [folder] first on the `PATH` of the commands
  /// after it, as [withFirstOnPath] does for the process: for a build's
  /// command, which a developer should be able to run as shown.
  String firstOnPathCommand(String folder) => switch (this) {
    posix => 'export PATH="$folder:\$PATH"',
    windows => 'set "PATH=$folder;%PATH%"',
  };

  /// [environment], with [folder] first on its `PATH`.
  ///
  /// On Windows the variable is `Path` as often as `PATH`, and names are not
  /// case sensitive, so the one already there is the one changed. A copy of
  /// `Platform.environment` is an ordinary map, which would otherwise gain a
  /// second, shadowing entry.
  Map<String, String> withFirstOnPath(
    Map<String, String> environment,
    String folder,
  ) {
    final name = switch (this) {
      posix => 'PATH',
      windows =>
        environment.keys
                .where((key) => key.toUpperCase() == 'PATH')
                .firstOrNull ??
            'PATH',
    };
    final separator = this == windows ? ';' : ':';
    final rest = environment[name];
    return {
      ...environment,
      name: rest == null || rest.isEmpty ? folder : '$folder$separator$rest',
    };
  }
}
