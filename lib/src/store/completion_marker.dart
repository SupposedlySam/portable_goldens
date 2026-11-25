import 'dart:convert';
import 'dart:io';

/// The `.complete` file a build writes last, inside its temporary folder,
/// before the folder is renamed into place: what was built, by which
/// command, and which images the build wrote.
///
/// A folder without one is a build that never finished, from an older version
/// or a hand copy, and is not read. Nor is one whose marker does not parse.
final class CompletionMarker {
  /// A marker for [files] of [commit] and [unit], written by [command].
  const new({
    required this.commit,
    required this.unit,
    required this.command,
    required this.files,
    required this.builtAt,
  });

  /// The marker in [dir], or null when there is none or it does not parse.
  static CompletionMarker? read(Directory dir) {
    try {
      final text = fileIn(dir).readAsStringSync();
      if (jsonDecode(text) case {
        'commit': final String commit,
        'unit': final String unit,
        'command': final String command,
        'files': final List<Object?> files,
        'builtAt': final String builtAt,
      }) {
        return CompletionMarker(
          commit: commit,
          unit: unit,
          command: command,
          files: {for (final path in files.cast<String>()) path},
          builtAt: DateTime.parse(builtAt),
        );
      }
    } on Object {
      // Missing, half written, or not a marker: unread, as if absent.
    }
    return null;
  }

  /// The commit built.
  final String commit;

  /// The package built, as `PackageLocation.unit` names it.
  final String unit;

  /// The command that built it, as it could be pasted into a shell.
  final String command;

  /// The package-relative images the build wrote: the only baselines in the
  /// folder. Anything else in it was not written by this build.
  final Set<String> files;

  /// When the build finished.
  final DateTime builtAt;

  /// Writes the marker into [dir].
  void writeTo(Directory dir) => fileIn(dir).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'commit': commit,
      'unit': unit,
      'builtAt': builtAt.toIso8601String(),
      'command': command,
      'files': files.toList()..sort(),
    }),
  );

  /// The marker's file in [dir].
  static File fileIn(Directory dir) => File('${dir.path}/.complete');
}
