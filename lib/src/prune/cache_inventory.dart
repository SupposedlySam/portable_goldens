import 'dart:io';

import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/machine/machine_key.dart';
import 'package:portable_goldens/src/store/baseline_store.dart';
import 'package:portable_goldens/src/store/commit_baselines.dart';
import 'package:portable_goldens/src/store/file_entries.dart';

/// What the cache holds, as `prune` judges it: each machine folder, and in
/// it each commit's baselines for each package.
///
/// Only what this package writes is in it: a machine folder is named like a
/// [MachineKey.id] and has a manifest, a commit folder is named like a
/// commit, and a unit's entries are named as [CommitBaselines] names them.
/// Anything else is [foreign] and left alone, since the cache's folder can
/// be moved ([cacheEnvironmentVariable](package:portable_goldens/src/store/cache_root.dart))
/// to one that holds other things.
final class CacheInventory {
  new _(this.root, this.machines, this.foreign);

  /// What is under [root] now; empty when there is no such folder.
  factory scan(String root) {
    final machines = <CachedMachine>[];
    final foreign = <String>[];
    for (final entity in entriesOf(Directory(root))) {
      final name = nameOf(entity);
      if (entity is Directory &&
          MachineKey.isId(name) &&
          BaselineStore.manifestIn(entity).existsSync()) {
        machines.add(CachedMachine._scan(entity, name, foreign));
      } else {
        foreign.add(entity.path);
      }
    }
    machines.sort((a, b) => a.id.compareTo(b.id));
    return CacheInventory._(root, machines, foreign..sort());
  }

  /// The cache's folder.
  final String root;

  /// Its machine folders, by id.
  final List<CachedMachine> machines;

  /// What is in the cache that this package did not write, by path.
  final List<String> foreign;
}

/// One machine folder: `<root>/<key id>/`, the baselines of one machine
/// key, which may be this machine's or one from before an update.
final class CachedMachine {
  new _(this.dir, this.id, this.units, {required this.hasForeign});

  factory _scan(Directory dir, String id, List<String> foreign) {
    final units = <CachedUnit>[];
    var hasForeign = false;
    // By name, not path: a listing on Windows joins with `\`, the folder's
    // own paths with `/`, so the paths never matched there (CI, 2026-11-25).
    final manifest = nameOf(BaselineStore.manifestIn(dir));
    for (final entity in entriesOf(dir)) {
      if (entity is File && nameOf(entity) == manifest) continue;
      final name = nameOf(entity);
      if (entity is! Directory || !isFullSha(name)) {
        foreign.add(entity.path);
        hasForeign = true;
        continue;
      }
      final names = <String>{};
      for (final inCommit in entriesOf(entity)) {
        final unit = CommitBaselines.unitOf(
          nameOf(inCommit),
          isDirectory: inCommit is Directory,
        );
        if (unit == null) {
          foreign.add(inCommit.path);
          hasForeign = true;
        } else {
          names.add(unit);
        }
      }
      for (final unit in names.toList()..sort()) {
        units.add(CachedUnit._(id, CommitBaselines(entity, name, unit)));
      }
    }
    return CachedMachine._(dir, id, units, hasForeign: hasForeign);
  }

  /// The folder.
  final Directory dir;

  /// The key id it is named by.
  final String id;

  /// Every commit's baselines in it, by commit and then package.
  final List<CachedUnit> units;

  /// Whether it holds anything this package did not write, which keeps it.
  final bool hasForeign;

  /// The key its manifest records, or null when it records none.
  MachineKey? get key => BaselineStore.recordedKey(manifest);

  /// The manifest, whose modification time is when the folder's baselines
  /// were last opened.
  File get manifest => BaselineStore.manifestIn(dir);

  /// When the folder was last opened.
  DateTime? get lastUsed => modifiedAt(manifest);
}

/// One commit's baselines for one package, in one machine folder: what
/// prune removes, or keeps, as a whole.
final class CachedUnit {
  new _(this.machineId, this.baselines);

  /// The key id of the machine folder it is in.
  final String machineId;

  /// The baselines, which name the commit and the package.
  final CommitBaselines baselines;

  /// The commit.
  String get commit => baselines.commit;

  /// When it was last used ([CommitBaselines.lastUsed]).
  DateTime? get lastUsed => baselines.lastUsed;

  /// How it is named in prune's output: `<key id>/<commit>/<unit>`, the
  /// commit shortened.
  String get label => '$machineId/${shortSha(commit)}/${baselines.unit}';

  /// The bytes its files take, links not followed.
  int get bytes =>
      baselines.entries.fold(0, (sum, e) => sum + bytesUnder(e.path));
}
