import 'dart:io';

import 'package:portable_goldens/src/build/checkout_unavailable.dart';
import 'package:portable_goldens/src/git/git_repo.dart';

/// A detached `git worktree` of one commit, which lives as long as one
/// callback and is removed after it, however it ends.
final class ThrowawayCheckout {
  new _(this._repo, this.path, this.packageDir);

  /// The git arguments that check out a checkout's submodules, at the
  /// commits it records, and theirs in turn.
  static const submoduleArguments = [
    'submodule',
    'update',
    '--init',
    '--recursive',
  ];

  final GitRepo _repo;

  /// The checkout's folder.
  final String path;

  /// The package's folder inside it, ending in `/`.
  final String packageDir;

  /// Whether the commit has submodules, which `git worktree add` leaves
  /// empty.
  bool get hasSubmodules => File('$path/.gitmodules').existsSync();

  /// Checks the submodules out, as [submoduleArguments] in [path]; null when
  /// git could not be started.
  ///
  /// Each is cloned from its URL: a worktree keeps its submodules' git
  /// folders apart from the developer's, so nothing they fetched is reused.
  Future<ProcessResult?> checkOutSubmodules() =>
      _repo.result(['-C', path, ..._noHooks, ...submoduleArguments]);

  /// Checks [commit] of [repo] out at [path], runs [body] with it, and
  /// removes it.
  ///
  /// The prune before `add` drops the registration a killed build left
  /// behind, so its path can be used again. The repository's hooks are not
  /// run: a checkout for rendering is not a checkout anybody works in.
  ///
  /// Throws [CheckoutUnavailable] when git cannot check [commit] out.
  static Future<T> use<T>(
    GitRepo repo,
    String commit,
    String path,
    Future<T> Function(ThrowawayCheckout checkout) body,
  ) async {
    await repo.result(['worktree', 'prune']);
    try {
      final added = await repo.result([
        ..._noHooks,
        'worktree',
        'add',
        '--detach',
        path,
        commit,
      ]);
      if (added == null || added.exitCode != 0) {
        throw CheckoutUnavailable(
          commit,
          added == null ? 'git could not be started' : '${added.stderr}'.trim(),
        );
      }
      return await body(
        ThrowawayCheckout._(repo, path, '$path/${repo.location.prefix}'),
      );
    } finally {
      await repo.result(['worktree', 'remove', '--force', path]);
      final left = Directory(path);
      if (left.existsSync()) left.deleteSync(recursive: true);
      await repo.result(['worktree', 'prune']);
    }
  }
}

// Git configuration that runs none of the repository's hooks.
final _noHooks = [
  if (!Platform.isWindows) ...['-c', 'core.hooksPath=/dev/null'],
];
