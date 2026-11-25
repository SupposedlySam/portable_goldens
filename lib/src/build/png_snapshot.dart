import 'dart:io';

import 'package:portable_goldens/src/git/path_style.dart';

/// Every png in a package at one moment, by package-relative path, with its
/// modification time: what a run wrote is what differs between two.
///
/// Tool output (`.dart_tool`, `build`) and failure images are skipped.
final class PngSnapshot {
  new _(this._times);

  /// The pngs in [packageDir] now, keyed with `/` between segments on every
  /// OS, as git and the cache name them.
  factory of(String packageDir) {
    final times = <String, DateTime>{};
    final root = Directory(packageDir);
    if (!root.existsSync()) return PngSnapshot._(times);
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.png')) continue;
      final path = PathStyle.current.relative(packageDir, entity.path);
      if (path == null || path.split('/').any(_skipped.contains)) continue;
      times[path] = entity.lastModifiedSync();
    }
    return PngSnapshot._(times);
  }

  static const _skipped = {'.dart_tool', 'build', 'failures'};

  final Map<String, DateTime> _times;

  /// The paths in this snapshot that are new or newer than in [before],
  /// sorted. A png untouched since [before] was not written in between.
  List<String> writtenSince(PngSnapshot before) => [
    for (final MapEntry(key: path, value: time) in _times.entries)
      if (before._times[path] != time) path,
  ]..sort();
}
