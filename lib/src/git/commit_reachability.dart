import 'dart:io';

import 'package:portable_goldens/src/git/git_repo.dart';
import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/store/commit_baselines.dart';

/// Whether a commit is still part of a repository's history.
enum Reachability {
  /// A branch, tag, remote branch or other ref has it, or a worktree's HEAD.
  reachable,

  /// The repository has the commit and nothing reaches it: it was rebased,
  /// amended or squashed away, or its branch was deleted. Only the reflog
  /// and git's own garbage collection still know it.
  unreachable,

  /// The repository does not have the commit; another repository may. The
  /// cache is shared by every repository on the machine.
  absent,

  /// Git could not say, or there is no repository to ask. Never taken for
  /// [unreachable].
  unknown,
}

/// Asks one repository whether commits are reachable, each commit once.
///
/// Reachable is what a checkout could still need: a commit some ref
/// contains (`git for-each-ref --contains`), or that a worktree's HEAD
/// descends from (`git merge-base --is-ancestor`), since a detached
/// checkout is on no ref. Measured on git 2.50: a commit amended away is
/// contained by no ref, and `for-each-ref --contains` prints nothing and
/// exits 0; a commit the repository does not have exits 129.
final class CommitReachability {
  new _(this._repo, this._heads);

  /// No repository: every commit is [Reachability.unknown].
  factory none() => CommitReachability._(null, null);

  /// The reachability of commits in [repo].
  ///
  /// The worktrees' HEADs are read once. A throwaway checkout a build left
  /// behind is a worktree too, of the very commit it renders, and is not
  /// one anybody works in, so it does not count.
  static Future<CommitReachability> of(GitRepo repo) async =>
      CommitReachability._(repo, await _worktreeHeads(repo));

  final GitRepo? _repo;

  // Null when they could not be read: then no commit is unreachable.
  final List<String>? _heads;

  final _known = <String, Future<Reachability>>{};

  /// Whether [commit] is reachable here.
  Future<Reachability> reachabilityOf(String commit) =>
      _known[commit] ??= _ask(commit);

  Future<Reachability> _ask(String commit) async {
    final repo = _repo;
    if (repo == null) return Reachability.unknown;
    final has = await repo.result(['cat-file', '-e', '$commit^{commit}']);
    if (has == null) return Reachability.unknown;
    if (has.exitCode != 0) return Reachability.absent;
    final contained = await repo.result([
      'for-each-ref',
      '--contains',
      commit,
      '--count=1',
      '--format=%(refname)',
    ]);
    if (contained == null || contained.exitCode != 0) {
      return Reachability.unknown;
    }
    if ('${contained.stdout}'.trim().isNotEmpty) return Reachability.reachable;
    final heads = _heads;
    if (heads == null) return Reachability.unknown;
    var answered = true;
    for (final head in heads) {
      final ancestor = await repo.result([
        'merge-base',
        '--is-ancestor',
        commit,
        head,
      ]);
      switch (ancestor?.exitCode) {
        case 0:
          return Reachability.reachable;
        case 1:
          break;
        case _:
          answered = false;
      }
    }
    return answered ? Reachability.unreachable : Reachability.unknown;
  }
}

// The HEAD of each worktree that is someone's, from `git worktree list
// --porcelain`: blocks of `worktree <path>`, `HEAD <sha>`, then `branch
// <ref>` or `detached`, and `prunable` when its folder is gone.
Future<List<String>?> _worktreeHeads(GitRepo repo) async {
  final listed = await repo.result(['worktree', 'list', '--porcelain']);
  if (listed == null || listed.exitCode != 0) return null;
  final heads = <String>[];
  for (final block in '${listed.stdout}'.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    String? field(String name) => [
      for (final line in lines)
        if (line == name || line.startsWith('$name '))
          line.substring(name.length).trim(),
    ].firstOrNull;
    final path = field('worktree');
    final head = field('HEAD');
    if (path == null || head == null || field('prunable') != null) continue;
    if (_isThrowawayCheckout(path)) continue;
    heads.add(head);
  }
  return heads;
}

// A build's checkout: `.<unit>.tmp-<pid>-<time>-checkout` in a commit
// folder of the cache. Told by its shape, not by where the cache is, which
// a symbolic link can make look like two places.
bool _isThrowawayCheckout(String path) {
  final segments = File(path).uri.pathSegments.where((s) => s.isNotEmpty);
  if (segments.length < 2) return false;
  final name = segments.last;
  final parent = segments.elementAt(segments.length - 2);
  return name.startsWith('.') &&
      name.endsWith('-checkout') &&
      CommitBaselines.unitOf(name, isDirectory: true) != null &&
      isFullSha(parent);
}
