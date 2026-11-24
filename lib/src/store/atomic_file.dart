import 'dart:io';

/// Writes [contents] to [file] so that no reader ever sees half of it: into
/// a temporary file beside it, named for this process and moment, then
/// renamed into place, one atomic step.
///
/// Every test file runs in a process of its own and they all read the cache
/// and the report at once, so a plain write would be read half done.
void writeAtomically(File file, String contents) {
  File('${file.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp')
    ..writeAsStringSync(contents)
    ..renameSync(file.path);
}
