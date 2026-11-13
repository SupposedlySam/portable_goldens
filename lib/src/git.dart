import 'dart:io';

/// The git facts the baselines are built from, for one package in one repo.
///
/// Paths in and out are relative to the repository's top level, with `/`.
class GitRepo {
  GitRepo._(this.topLevel, this.packagePrefix);

  /// The repo [packageDir] is in, or null when there is no git or the folder
  /// is not inside a repository; the comparator then compares with the
  /// committed image, as a plain `LocalFileComparator` would.
  static Future<GitRepo?> open(String packageDir) async {
    final top = await _git(packageDir, ['rev-parse', '--show-toplevel']);
    final prefix = await _git(packageDir, ['rev-parse', '--show-prefix']);
    if (top == null || prefix == null) return null;
    return GitRepo._(top, prefix);
  }

  /// The working tree's top level.
  final String topLevel;

  /// The package's folder below [topLevel]: empty at the root, else ending in
  /// `/`, e.g. `packages/app/`.
  final String packagePrefix;

  /// Runs git in [topLevel]; null when git fails or is missing.
  Future<String?> run(List<String> args) => _git(topLevel, args);

  /// Whether the clone is shallow: its history stops at a boundary commit,
  /// which `git log -1 -- <path>` then names for every path older than it.
  Future<bool> isShallow() async =>
      await run(['rev-parse', '--is-shallow-repository']) == 'true';

  /// The commit that last changed [path], or null when no commit has it.
  ///
  /// `git log -1 -- <path>`, from HEAD or from [at], with git's default
  /// history simplification: a merge that took the file unchanged from one
  /// side is skipped in favour of the commit on that side that changed it,
  /// whose checkout renders the same image.
  Future<String?> lastCommitOf(String path, {String? at}) async {
    final sha = await run(['log', '-1', '--format=%H', ?at, '--', path]);
    return sha == null || sha.isEmpty ? null : sha;
  }

  /// The bytes of [path] as [commit] has it, or null when it has none.
  Future<List<int>?> show(String commit, String path) async {
    try {
      final result = await Process.run(
        'git',
        ['show', '$commit:$path'],
        workingDirectory: topLevel,
        stdoutEncoding: null,
      );
      return result.exitCode == 0 ? result.stdout as List<int> : null;
    } on ProcessException {
      return null;
    }
  }

  /// The commit this branch's own changes are measured from, for the report.
  ///
  /// The merge-base of HEAD with the default branch, not the default branch's
  /// tip: once main moves on, a diff against its tip would also hold every
  /// golden other people changed there since this branch left it, and list
  /// them as this branch's. [baseRef] overrides the default branch. Of the
  /// candidates that resolve (`origin/HEAD`, `origin/main`, `origin/master`,
  /// `main`, `master`), the newest merge-base wins: an `origin` that is a
  /// stale fork, or a local main nobody pulled, has an older one, and would
  /// hand this branch goldens it merged in from elsewhere. With none, it is
  /// HEAD, so only uncommitted changes count.
  Future<String?> branchBase({String? baseRef}) async {
    final candidates = baseRef != null
        ? [baseRef]
        : [
            ?await run(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']),
            'origin/main',
            'origin/master',
            'main',
            'master',
          ];
    String? newest;
    for (final ref in candidates) {
      final base = await run(['merge-base', 'HEAD', ref]);
      if (base == null || base.isEmpty) continue;
      if (newest == null ||
          await run(['merge-base', '--is-ancestor', newest, base]) != null) {
        newest = base;
      }
    }
    return newest ?? run(['rev-parse', 'HEAD']);
  }

  /// The paths whose working-tree content differs from HEAD: staged,
  /// unstaged, or new and not ignored. Such a png has no commit to render.
  Future<Set<String>> dirty() => changedSince('HEAD');

  /// The paths whose working-tree content differs from [base]: committed on
  /// this branch, staged, unstaged, or new and not ignored.
  Future<Set<String>> changedSince(String base) async {
    final tracked = await run(['diff', '--name-only', '--no-renames', base, '--']);
    final untracked = await run(['ls-files', '--others', '--exclude-standard']);
    return {
      for (final text in [tracked, untracked])
        if (text != null)
          for (final line in text.split('\n'))
            if (line.isNotEmpty) line,
    };
  }

  /// The tracked files matching [pathspec], from the top level.
  Future<List<String>> trackedFiles(String pathspec) async {
    final text = await run(['ls-files', '--', pathspec]);
    if (text == null || text.isEmpty) return const [];
    return text.split('\n').where((line) => line.isNotEmpty).toList();
  }
}

Future<String?> _git(String dir, List<String> args) async {
  try {
    final result = await Process.run('git', args, workingDirectory: dir);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  } on ProcessException {
    return null;
  }
}
