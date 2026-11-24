import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/store/build_failure.dart';
import 'package:portable_goldens/src/store/completion_marker.dart';
import 'package:portable_goldens/src/store/exclusive_lock.dart';

/// One commit's baselines for one package, on this machine: a folder that
/// is complete or absent, never half there.
final class CommitBaselines {
  /// The baselines of [commit] for [unit], kept in [commitDir].
  const new(this.commitDir, this.commit, this.unit);

  /// `<root>/<key id>/<commit>`: every package's baselines of [commit].
  final Directory commitDir;

  /// The commit rendered.
  final String commit;

  /// The package rendered, as `PackageLocation.unit` names it.
  final String unit;

  /// The finished folder: `<commit>/<unit>`.
  Directory get dir => Directory('${commitDir.path}/$unit');

  /// The record of the last failed build: `<commit>/<unit>.failed`.
  File get failureRecord => File('${commitDir.path}/$unit.failed');

  File get _lockFile => File('${commitDir.path}/$unit.lock');

  /// The marker of the finished build, or null when there is none.
  CompletionMarker? get marker => CompletionMarker.read(dir);

  /// Whether the baselines were built to the end.
  bool get isComplete => marker != null;

  /// The command that built them, for a message; null when not built.
  String? get command => marker?.command;

  /// The baseline of the package-relative [path], or null when there is
  /// none: only an image the marker lists, since anything else in the folder
  /// was not written by the build the marker records.
  File? baseline(String path) {
    if (!(marker?.files.contains(path) ?? false)) return null;
    final file = File('${dir.path}/$path');
    return file.existsSync() ? file : null;
  }

  /// Fills the folder with what [build] writes into the temporary folder it
  /// is handed, then renames it into place.
  ///
  /// Two test processes, or two worktrees, can want the same baselines at
  /// once; `flutter test` runs test files in parallel processes, so this is
  /// the normal case, not a race in theory. Two things make it safe:
  ///
  /// - **A lock** on `<unit>.lock` ([ExclusiveLock]). The second process
  ///   waits, then finds the folder complete and builds nothing.
  /// - **Build, mark, then rename.** The images and the `.complete` marker
  ///   go into `.<unit>.tmp-<pid>-<time>` and that folder is renamed to
  ///   `<unit>`, one atomic step; a reader sees no folder or a complete one.
  ///   This holds even where the lock does not, such as a cache on a network
  ///   share.
  ///
  /// A build that failed while this one waited is not run again: its record
  /// is newer than the wait, so its error is rethrown as [BuildFailure].
  Future<void> fill(Future<Built> Function(Directory into) build) async {
    if (isComplete) return;
    commitDir.createSync(recursive: true);
    final waitedFrom = DateTime.now();
    await ExclusiveLock(_lockFile).hold(() async {
      if (isComplete) return;
      if (_failureSince(waitedFrom) case final failure?) throw failure;
      _sweep();
      final temp = Directory(
        '${commitDir.path}/.$unit.tmp-$pid-'
        '${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        temp.createSync(recursive: true);
        final Built built;
        try {
          built = await build(temp);
        } on BuildFailure catch (failure) {
          failureRecord.writeAsStringSync(jsonEncode(failure.toJson()));
          rethrow;
        }
        CompletionMarker(
          commit: commit,
          unit: unit,
          command: built.command,
          files: built.files.toSet(),
          builtAt: DateTime.now(),
        ).writeTo(temp);
        _moveIntoPlace(temp);
        if (failureRecord.existsSync()) failureRecord.deleteSync();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });
  }

  // The failure another process recorded after [since], while this one
  // waited for the lock.
  BuildFailure? _failureSince(DateTime since) {
    final record = failureRecord;
    if (!record.existsSync() || !record.lastModifiedSync().isAfter(since)) {
      return null;
    }
    try {
      if (jsonDecode(record.readAsStringSync())
          case final Map<String, Object?> json) {
        return BuildFailure.fromJson(json);
      }
    } on FormatException {
      // Half written or not a record: build again, as if there were none.
    }
    return null;
  }

  // Where the lock does not hold, another process may have finished first;
  // its folder is as good as this one and stays. A folder without a marker
  // is a build that stopped half way; it goes, so the rename can take its
  // name.
  void _moveIntoPlace(Directory temp) {
    if (isComplete) return;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    try {
      temp.renameSync(dir.path);
    } on FileSystemException {
      if (!isComplete) rethrow;
    }
  }

  // Deletes what builds of [unit] left in [commitDir] when they were killed
  // before their own cleanup: `.<unit>.tmp-*`, the temporary folder and the
  // checkout beside it. Called under the lock, so none of them is a build
  // still running here; a build orphaned by a killed test process may still
  // be running in one, and fails, which nothing is waiting for.
  void _sweep() {
    for (final entity in commitDir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entity is Directory && name.startsWith('.$unit.tmp-')) {
        try {
          entity.deleteSync(recursive: true);
        } on FileSystemException {
          // Another sweep got there first.
        }
      }
    }
  }
}
