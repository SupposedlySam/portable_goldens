import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/machine/machine_key.dart';
import 'package:portable_goldens/src/store/atomic_file.dart';
import 'package:portable_goldens/src/store/commit_baselines.dart';
import 'package:portable_goldens/src/store/last_use.dart';

/// This machine's baselines, under `<root>/<key id>/`.
///
/// ```text
/// <root>/<key id>/manifest.json            the key's readable values
/// <root>/<key id>/<commit>/<unit>/         one commit's renders, for one package
/// <root>/<key id>/<commit>/<unit>/.complete
/// <root>/<key id>/<commit>/<unit>.lock     held while it is built
/// <root>/<key id>/<commit>/<unit>.failed   the last build that failed
/// ```
///
/// The manifest's and each marker's modification time is when they were
/// last used, which is what `prune` goes by.
///
/// The unit is the package's folder in its repository (`root` at the top),
/// so two packages of one monorepo never fill each other's commit folder.
final class BaselineStore {
  new _(this.machineDir, this.key);

  /// Opens this machine's folder under [root], creating it.
  ///
  /// A folder whose manifest names another key is emptied first: its name
  /// is a hash of the key, so that is a hash collision or a hand edit, and in
  /// neither case were its images rendered by this machine.
  ///
  /// A manifest that cannot be read is only rewritten. It says nothing about
  /// the images, which the folder's name already ties to this key, and every
  /// test process opens the store at once: emptying the folder then would
  /// delete what the others are reading and building.
  factory open(String root, MachineKey key) {
    final dir = Directory('$root/${key.id}');
    final manifest = manifestIn(dir);
    final recorded = recordedKey(manifest);
    if (recorded == key) {
      // In use: `prune` removes a machine folder nobody opened for a while.
      recordUse(manifest);
      return BaselineStore._(dir, key);
    }
    if (recorded != null) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    writeAtomically(
      manifest,
      const JsonEncoder.withIndent('  ').convert(key.toJson()),
    );
    return BaselineStore._(dir, key);
  }

  /// The manifest of the machine folder [dir].
  static File manifestIn(Directory dir) => File('${dir.path}/manifest.json');

  /// The key [manifest] records, or null when it records none.
  static MachineKey? recordedKey(File manifest) {
    try {
      if (jsonDecode(manifest.readAsStringSync())
          case final Map<String, Object?> json) {
        return MachineKey.fromJson(json);
      }
    } on Object {
      // Missing, half written, or not a key: unknown.
    }
    return null;
  }

  /// `<root>/<key id>`.
  final Directory machineDir;

  /// The machine these baselines belong to.
  final MachineKey key;

  /// The baselines of [commit] for the package [unit].
  CommitBaselines at(String commit, String unit) =>
      CommitBaselines(Directory('${machineDir.path}/$commit'), commit, unit);
}
