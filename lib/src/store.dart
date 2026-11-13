import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'machine_key.dart';

/// The environment variable that moves the cache.
const cacheEnvironmentVariable = 'MACHINE_GOLDENS_CACHE';

/// Where baselines live when [cacheEnvironmentVariable] is not set: the
/// user's cache folder, outside every repository.
///
/// One folder per user, not per checkout, so every worktree and clone of a
/// repository shares the baselines: they are keyed by commit, and a commit
/// renders the same image wherever it is checked out on the same machine.
String defaultCacheRoot({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final override = env[cacheEnvironmentVariable];
  if (override != null && override.isNotEmpty) return override;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  if (Platform.isMacOS) return '$home/Library/Caches/machine_goldens';
  if (Platform.isWindows) {
    final local = env['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    return '$local\\machine_goldens';
  }
  final xdg = env['XDG_CACHE_HOME'];
  return '${xdg != null && xdg.isNotEmpty ? xdg : '$home/.cache'}/machine_goldens';
}

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
/// The unit is the package's folder in its repository (`root` at the top),
/// so two packages of one monorepo never fill each other's commit folder.
class BaselineStore {
  BaselineStore._(this.machineDir, this.key);

  /// Opens this machine's folder under [root], creating it.
  ///
  /// A folder whose manifest disagrees with [key] is emptied first: its name
  /// is a hash of the key, so that is a hash collision or a hand edit, and in
  /// neither case were its images rendered by this machine.
  static BaselineStore open(String root, MachineKey key) {
    final dir = Directory('$root/${key.id}');
    final manifest = File('${dir.path}/manifest.json');
    if (manifest.existsSync()) {
      MachineKey? recorded;
      try {
        recorded = MachineKey.fromJson(
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>,
        );
      } on Object {
        recorded = null;
      }
      if (recorded != key) dir.deleteSync(recursive: true);
    }
    if (!manifest.existsSync()) {
      dir.createSync(recursive: true);
      manifest.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(key.toJson()),
      );
    }
    return BaselineStore._(dir, key);
  }

  /// `<root>/<key id>`.
  final Directory machineDir;

  /// The machine these baselines belong to.
  final MachineKey key;

  /// The finished baselines of [commit] for [unit].
  Directory unitDir(String commit, String unit) =>
      Directory('${machineDir.path}/$commit/$unit');

  /// Whether [commit]'s baselines for [unit] were built to the end.
  ///
  /// The marker is written last, inside the temporary folder, before the
  /// folder is renamed into place; a folder without it is a build that never
  /// finished, from an older version or a hand copy, and is not read.
  bool isComplete(String commit, String unit) =>
      File('${unitDir(commit, unit).path}/.complete').existsSync();

  /// The baseline of the package-relative [path], or null when there is none.
  File? baseline(String commit, String unit, String path) {
    if (!isComplete(commit, unit)) return null;
    final file = File('${unitDir(commit, unit).path}/$path');
    return file.existsSync() ? file : null;
  }

  /// The record of the last failed build of [commit] for [unit].
  File failureRecord(String commit, String unit) =>
      File('${machineDir.path}/$commit/$unit.failed');

  /// Fills [commit]'s folder for [unit] with what [build] writes into the
  /// temporary folder it is handed, then renames it into place.
  ///
  /// Two test processes, or two worktrees, can want the same baseline at
  /// once; `flutter test` runs test files in parallel processes, so this is
  /// the normal case, not a race in theory. Two things make it safe:
  ///
  /// - **A lock** on `<unit>.lock` (an advisory `fcntl` lock, which the OS
  ///   releases when its process dies, so a killed build never leaves it
  ///   held). The second process waits, then finds the folder complete and
  ///   builds nothing.
  /// - **Build, mark, then rename.** The images and the `.complete` marker
  ///   go into `.<unit>.tmp-<pid>-<time>` and that folder is renamed to
  ///   `<unit>`, one atomic step; a reader sees no folder or a complete one.
  ///   This holds even where the lock does not, such as a cache on a network
  ///   share.
  ///
  /// A build that failed while this one waited is not run again: its record
  /// is newer than the wait, so its error is rethrown as [BuildFailure].
  Future<void> fill(
    String commit,
    String unit,
    Future<Built> Function(Directory into) build,
  ) async {
    if (isComplete(commit, unit)) return;
    final commitDir = Directory('${machineDir.path}/$commit')
      ..createSync(recursive: true);
    final waitedFrom = DateTime.now();
    await _withLock(File('${commitDir.path}/$unit.lock'), () async {
      if (isComplete(commit, unit)) return;
      final record = failureRecord(commit, unit);
      if (record.existsSync() && record.lastModifiedSync().isAfter(waitedFrom)) {
        throw BuildFailure.fromJson(
          jsonDecode(record.readAsStringSync()) as Map<String, Object?>,
        );
      }
      final temp = Directory(
        '${commitDir.path}/.$unit.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        temp.createSync(recursive: true);
        final Built built;
        try {
          built = await build(temp);
        } on BuildFailure catch (failure) {
          record.writeAsStringSync(jsonEncode(failure.toJson()));
          rethrow;
        }
        File('${temp.path}/.complete').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'commit': commit,
            'unit': unit,
            'builtAt': DateTime.now().toIso8601String(),
            'command': built.command,
            'files': built.files,
          }),
        );
        // Where the lock does not hold, another process may have finished
        // first; its folder is as good as this one and stays. A folder
        // without a marker is a build that stopped half way; it goes, so the
        // rename can take its name.
        final target = unitDir(commit, unit);
        if (isComplete(commit, unit)) return;
        if (target.existsSync()) target.deleteSync(recursive: true);
        try {
          temp.renameSync(target.path);
        } on FileSystemException {
          if (!isComplete(commit, unit)) rethrow;
        }
        if (record.existsSync()) record.deleteSync();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });
  }
}

/// What a build wrote, and the command that wrote it.
class Built {
  /// [files] (package-relative) were written by [command].
  const Built(this.files, this.command);

  /// The package-relative paths of the images.
  final List<String> files;

  /// The command, as it could be pasted into a shell.
  final String command;
}

/// The command recorded in a complete folder's marker, for a message.
String? builtCommand(Directory unitDir) {
  try {
    final marker = File('${unitDir.path}/.complete').readAsStringSync();
    return (jsonDecode(marker) as Map<String, Object?>)['command'] as String?;
  } on Object {
    return null;
  }
}

/// A baseline build that did not finish: always a loud test failure.
class BuildFailure implements Exception {
  /// A failure of [command] while building [commit]'s baselines.
  const BuildFailure({
    required this.commit,
    required this.command,
    required this.message,
    this.output = '',
  });

  /// A failure as [toJson] wrote it.
  factory BuildFailure.fromJson(Map<String, Object?> json) => BuildFailure(
    commit: json['commit'] as String,
    command: json['command'] as String,
    message: json['message'] as String,
    output: json['output'] as String? ?? '',
  );

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
  String toString() => [
    'machine_goldens could not build the baselines of commit $commit: $message',
    'Command: $command',
    if (output.isNotEmpty) 'Output (end):\n$output',
  ].join('\n');
}

// Locks taken in this isolate. An fcntl lock belongs to the process, so a
// second taker in the same process would get it at once; this makes it wait.
final _held = <String, Future<void>>{};

Future<void> _withLock(File file, Future<void> Function() body) async {
  for (var held = _held[file.path]; held != null; held = _held[file.path]) {
    await held;
  }
  final done = Completer<void>();
  _held[file.path] = done.future;
  final handle = file.openSync(mode: FileMode.append);
  try {
    var told = false;
    while (true) {
      try {
        handle.lockSync(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (!told) {
          stderr.writeln('machine_goldens: waiting for another build of ${file.path}');
          told = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    await body();
  } finally {
    try {
      handle.unlockSync();
    } on FileSystemException {
      // Never held: the body did not run.
    }
    handle.closeSync();
    _held.remove(file.path);
    done.complete();
  }
}
