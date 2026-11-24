/// What a build wrote, and the command that wrote it.
final class Built {
  /// [files] (package-relative) were written by [command].
  const new(this.files, this.command);

  /// The package-relative paths of the images.
  final List<String> files;

  /// The command, as it could be pasted into a shell.
  final String command;
}

/// A baseline build that did not finish: always a loud test failure.
final class BuildFailure implements Exception {
  /// A failure of [command] while building [commit]'s baselines.
  const new({
    required this.commit,
    required this.command,
    required this.message,
    this.output = '',
  });

  /// A failure as [toJson] wrote it; throws [FormatException] when it is not
  /// one.
  factory fromJson(Map<String, Object?> json) => switch (json) {
    {
      'commit': final String commit,
      'command': final String command,
      'message': final String message,
    } =>
      BuildFailure(
        commit: commit,
        command: command,
        message: message,
        output: json['output'] as String? ?? '',
      ),
    _ => throw FormatException('Not a build failure', json),
  };

  /// The commit whose baselines were being built.
  final String commit;

  /// The command that failed, as it could be pasted into a shell.
  final String command;

  /// What went wrong, in a sentence.
  final String message;

  /// The end of the command's output.
  final String output;

  /// The failure as JSON, for the record beside the folder.
  Map<String, String> toJson() => {
    'commit': commit,
    'command': command,
    'message': message,
    'output': output,
  };

  @override
  String toString() {
    const what = 'portable_goldens could not build the baselines of commit';
    return [
      '$what $commit: $message',
      'Command: $command',
      if (output.isNotEmpty) 'Output (end):\n$output',
    ].join('\n');
  }
}
