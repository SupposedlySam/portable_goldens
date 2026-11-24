import 'dart:io';

import 'package:portable_goldens/src/git/package_location.dart';
import 'package:portable_goldens/src/process/process_runner.dart';

/// Every question this package asks git, for one package in one repository.
///
/// Paths in and out are relative to the repository's top level, with `/`;
/// [location] converts them.
final class GitRepo {
  new _(this.location, this._run);

  /// The repository [packageDir] is in, or null when there is no git or the
  /// folder is not inside a repository; the comparator then compares with the
  /// committed image, as a plain `LocalFileComparator` would.
  static Future<GitRepo?> open(
    String packageDir, {
    ProcessRunner runProcess = Process.run,
  }) async {
    Future<String?> ask(List<String> args) async =>
        _stdout(await _start(runProcess, args, packageDir));
    final top = await ask(['rev-parse', '--show-toplevel']);
    final prefix = await ask(['rev-parse', '--show-prefix']);
    if (top == null || prefix == null) return null;
    return GitRepo._(
      PackageLocation(topLevel: top, prefix: prefix, packageDir: packageDir),
      runProcess,
    );
  }

  /// Where the package is in the repository.
  final PackageLocation location;

  final ProcessRunner _run;

  /// Runs git in the top level; null when git could not be started.
  Future<ProcessResult?> result(List<String> args) =>
      _start(_run, args, location.topLevel);

  /// Runs git in the top level and returns its trimmed output; null when git
  /// failed or could not be started.
  Future<String?> run(List<String> args) async => _stdout(await result(args));

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
      final result = await _run(
        'git',
        ['show', '$commit:$path'],
        workingDirectory: location.topLevel,
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
    return newest ?? await run(['rev-parse', 'HEAD']);
  }

  /// The paths whose working-tree content differs from HEAD: staged,
  /// unstaged, or new and not ignored. Such a png has no commit to render.
  Future<Set<String>> dirty() => changedSince('HEAD');

  /// The paths whose working-tree content differs from [base]: committed on
  /// this branch, staged, unstaged, or new and not ignored.
  Future<Set<String>> changedSince(String base) async => {
    ..._lines(await run(['diff', '--name-only', '--no-renames', base, '--'])),
    ..._lines(await run(['ls-files', '--others', '--exclude-standard'])),
  };

  /// The tracked files matching [pathspec], from the top level.
  Future<List<String>> trackedFiles(String pathspec) async =>
      _lines(await run(['ls-files', '--', pathspec]));

  /// The tracked and the untracked, unignored files matching [pathspec].
  Future<List<String>> workingFiles(String pathspec) async => _lines(
    await run([
      'ls-files',
      '--cached',
      '--others',
      '--exclude-standard',
      '--',
      pathspec,
    ]),
  );
}

Future<ProcessResult?> _start(
  ProcessRunner run,
  List<String> args,
  String dir,
) async {
  try {
    return await run('git', args, workingDirectory: dir);
  } on ProcessException {
    return null;
  }
}

String? _stdout(ProcessResult? result) => result == null || result.exitCode != 0
    ? null
    : (result.stdout as String).trim();

List<String> _lines(String? text) => [
  for (final line in (text ?? '').split('\n'))
    if (line.isNotEmpty) line,
];
