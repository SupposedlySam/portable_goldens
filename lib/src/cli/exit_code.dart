/// What a command's process exits with.
enum ExitCode {
  /// It did what it was asked, and found nothing wrong.
  success(0),

  /// It ran and found a problem: a build failed, a golden failed.
  failure(1),

  /// It was called wrongly: `EX_USAGE` from `sysexits.h`.
  usage(64);

  new(this.code);

  /// The number the process exits with.
  final int code;
}
