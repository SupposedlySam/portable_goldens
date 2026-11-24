import 'dart:io';

/// The things a test process says once, however many goldens or test files
/// run in it: why it compares with the committed images, why it is not
/// installed. Said on every golden, they would bury the failures.
final class Notices {
  /// Notices written to [sink].
  new(this.sink);

  /// The process's notices, written to stderr.
  static Notices process = Notices(stderr);

  /// Where notices are written.
  final StringSink sink;

  final _said = <String>{};

  /// Writes `portable_goldens: <message>` unless it was said already.
  void once(String message) {
    if (_said.add(message)) sink.writeln('portable_goldens: $message');
  }
}
