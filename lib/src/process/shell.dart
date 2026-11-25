import 'dart:io';

/// The shell a command line from the user's configuration runs in, and how
/// its `PATH` is written.
///
/// A setup step is a command line, as in a CI `run:` or a melos script, so it
/// runs the way a developer would type it: quoting, `&&` and variables
/// included. Splitting it into arguments here would be a second, weaker shell.
enum Shell {
  /// `/bin/sh -c`, with `:` between `PATH` entries.
  posix,

  /// `cmd.exe /d /s /c`, with `;` between `PATH` entries. `/d` skips the
  /// user's AutoRun commands, so a build does not depend on them.
  windows;

  /// The shell of the OS this runs on.
  static Shell get current => Platform.isWindows ? windows : posix;

  /// The executable that runs a command line.
  String get executable => switch (this) {
    posix => '/bin/sh',
    windows => 'cmd.exe',
  };

  /// The arguments that run [commandLine] in [executable].
  List<String> arguments(String commandLine) => switch (this) {
    posix => ['-c', commandLine],
    windows => ['/d', '/s', '/c', commandLine],
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
