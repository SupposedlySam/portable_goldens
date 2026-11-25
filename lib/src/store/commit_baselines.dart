import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/store/build_failure.dart';
import 'package:portable_goldens/src/store/completion_marker.dart';
import 'package:portable_goldens/src/store/exclusive_lock.dart';
import 'package:portable_goldens/src/store/file_entries.dart';
import 'package:portable_goldens/src/store/last_use.dart';

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

  String get _tempPrefix => '.$unit$_temp';

  static const _temp = '.tmp-';
  static const _failed = '.failed';
  static const _lock = '.lock';

  /// The unit an entry of a commit folder named [name] belongs to, or null
  /// when no build wrote it: the inverse of the names above.
  ///
  /// A unit's folder is `<unit>`, a temporary folder or checkout
  /// `.<unit>.tmp-<pid>-<time>[-checkout]`, and its files `<unit>.failed`
  /// and `<unit>.lock`. A unit is a package's folder, which may have a dot
  /// in it, so the suffix decides, not the first dot.
  static String? unitOf(String name, {required bool isDirectory}) {
    if (isDirectory) {
      if (!name.startsWith('.')) return name;
      final temp = name.lastIndexOf(_temp);
      return temp > 1 ? name.substring(1, temp) : null;
    }
    for (final suffix in const [_failed, _lock]) {
      if (name.endsWith(suffix) && name.length > suffix.length) {
        return name.substring(0, name.length - suffix.length);
      }
    }
    return null;
  }

  /// Everything of [unit] in [commitDir]: its folder, its records, and what
  /// builds killed before their cleanup left.
  List<FileSystemEntity> get entries => [
    for (final entity in entriesOf(commitDir))
      if (unitOf(nameOf(entity), isDirectory: entity is Directory) == unit)
        entity,
  ];

  /// When the baselines were last used: the marker's modification time,
  /// which [baseline] and a finished build set. Without a marker, the
  /// newest of [entries], such as the last failed build; null when there is
  /// nothing.
  DateTime? get lastUsed {
    if (modifiedAt(markerFile) case final used?) return used;
    DateTime? newest;
    for (final entity in entries) {
      if (modifiedAt(entity) case final time?
          when newest == null || time.isAfter(newest)) {
        newest = time;
      }
    }
    return newest;
  }

  /// Removes everything of [unit] here, holding its lock, and [commitDir]
  /// when nothing else is left in it. Returns false, removing nothing, when
  /// a build holds the lock.
  ///
  /// The lock file goes too, while held: a build that was already waiting
  /// on it then holds a lock nobody else can see, so a third may build
  /// beside it. That costs a duplicate build, never a wrong baseline, since
  /// each builds into its own temporary folder and renames it into place
  /// ([fill]). Throws [FileSystemException] when something cannot be
  /// removed.
  Future<bool> remove() async {
    if (!commitDir.existsSync()) return true;
    final removed = await ExclusiveLock(_lockFile).tryHold(() async {
      for (final entity in entries) {
        if (entity.path != _lockFile.path) entity.deleteSync(recursive: true);
      }
      _lockFile.deleteSync();
    });
    if (removed) {
      try {
        commitDir.deleteSync();
      } on FileSystemException {
        // Another unit's baselines are in it still.
      }
    }
    return removed;
  }

  /// The marker of the finished build, or null when there is none.
  CompletionMarker? get marker => CompletionMarker.read(dir);

  /// Whether the baselines were built to the end.
  bool get isComplete => marker != null;

  /// The command that built them, for a message; null when not built.
  String? get command => marker?.command;

  /// The baseline of the package-relative [path], or null when there is
  /// none: only an image the marker lists, since anything else in the folder
  /// was not written by the build the marker records.
  ///
  /// Finding one records that the baselines are in use ([recordUse] on the
  /// marker), which keeps `prune` from removing them.
  File? baseline(String path) {
    if (!(marker?.files.contains(path) ?? false)) return null;
    final file = File('${dir.path}/$path');
    if (!file.existsSync()) return null;
    recordUse(markerFile);
    return file;
  }

  /// The marker's file, `<commit>/<unit>/.complete`, whose modification time
  /// is when the baselines were last used.
  File get markerFile => CompletionMarker.fileIn(dir);

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
        '${commitDir.path}/$_tempPrefix$pid-'
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
    for (final entity in entries) {
      if (entity is Directory && nameOf(entity).startsWith(_tempPrefix)) {
        try {
          entity.deleteSync(recursive: true);
        } on FileSystemException {
          // Another sweep got there first.
        }
      }
    }
  }
}
