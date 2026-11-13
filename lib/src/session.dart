import 'dart:io';

import 'builder.dart';
import 'git.dart';
import 'machine_key.dart';
import 'store.dart';

/// The environment variable that names the ref a branch is measured from, in
/// place of the remote's default branch.
const baseEnvironmentVariable = 'MACHINE_GOLDENS_BASE';

/// What one golden is compared against.
sealed class GoldenBaseline {
  const GoldenBaseline();
}

/// This machine's render of the commit that last changed the golden.
class MachineBaseline extends GoldenBaseline {
  /// [file] is [commit]'s render on the machine [keyId] names.
  const MachineBaseline(this.file, this.commit, this.keyId);

  /// The image.
  final File file;

  /// The commit that last changed the committed png.
  final String commit;

  /// The machine's key id.
  final String keyId;
}

/// The png differs from HEAD, staged, unstaged or new: no commit has it to
/// render, so it is compared exactly with itself in the working tree.
///
/// That png is normally what `--update-goldens` just wrote on this machine,
/// so the compare is this machine against this machine. Once committed, the
/// golden has a commit to render, and is a [MachineBaseline] again.
class WorkingTreeBaseline extends GoldenBaseline {
  /// The png in the working tree.
  const WorkingTreeBaseline();
}

/// How this branch changed a golden, for the report: what the png was when
/// the branch left the default branch.
class BranchChange {
  /// The branch changed the golden since [base]; [image] is what it was
  /// there, described by [was], or null when the golden is new.
  const BranchChange({required this.base, required this.image, required this.was});

  /// The commit the branch is measured from.
  final String base;

  /// The golden as it was at [base]: this machine's render where it can be
  /// built, else the png committed there.
  final List<int>? image;

  /// What [image] is, in words.
  final String was;
}

/// The committed image itself, as a plain `LocalFileComparator` would use.
class CommittedBaseline extends GoldenBaseline {
  /// Machine baselines do not apply, for [reason].
  const CommittedBaseline(this.reason);

  /// Why, in a phrase.
  final String reason;
}

/// Finds the baseline of each golden of one package, building what is
/// missing. One per test process, shared by every golden in it.
class MachineGoldens {
  /// The baselines of the package at [packageDir].
  ///
  /// The rest is for tests: a fake [key] stands in for an OS update, a
  /// [runProcess] for `flutter`.
  MachineGoldens({
    required this.packageDir,
    Map<String, String>? environment,
    this._key,
    this._cacheRoot,
    this.goldenTestMarker = 'matchesGoldenFile',
    this._runProcess,
  }) : environment = environment ?? Platform.environment;

  /// The package's folder.
  final String packageDir;

  /// The environment this runs in.
  final Map<String, String> environment;

  /// A commit's test file builds baselines when its source contains this.
  final String goldenTestMarker;

  final MachineKey? _key;
  final String? _cacheRoot;
  final ProcessRunner? _runProcess;

  late final Future<_Context> _context = _open();
  final _fills = <String, Future<void>>{};

  /// The key this machine's baselines are filed under.
  MachineKey get key => _key ?? MachineKey.current(environment: environment);

  /// The baseline of the golden at [path] (absolute, or relative to the
  /// package).
  ///
  /// Throws [BuildFailure] when the baseline had to be built and the build
  /// failed, or ran and did not render this golden.
  Future<GoldenBaseline> baselineFor(String path) async {
    final context = await _context;
    if (context.fallback case final reason?) return CommittedBaseline(reason);
    final repo = context.repo!;
    final relative = _relativeTo(repo.topLevel, path);
    if (relative == null) {
      return const CommittedBaseline('the golden is outside the repository');
    }
    if (context.dirty.contains(relative)) return const WorkingTreeBaseline();
    final commit = await repo.lastCommitOf(relative);
    if (commit == null) {
      return const CommittedBaseline('no commit has the golden');
    }
    final unit = context.unit;
    final inPackage = relative.substring(repo.packagePrefix.length);
    final store = context.store!;
    try {
      await build(commit);
    } on CheckoutUnavailable catch (unavailable) {
      return CommittedBaseline('$unavailable');
    }
    final file = store.baseline(commit, unit, inPackage);
    if (file == null) {
      throw BuildFailure(
        commit: commit,
        command:
            builtCommand(store.unitDir(commit, unit)) ?? '(not recorded)',
        message: 'its golden tests ran on this machine and did not write '
            '$inPackage. Is the test that draws it in a file whose source '
            'contains "$goldenTestMarker"?',
      );
    }
    return MachineBaseline(file, commit, store.key.id);
  }

  /// The goldens matching [pathspec] (a git pathspec, relative to the
  /// package) whose baselines are missing on this machine, by the commit
  /// that last changed each.
  ///
  /// A png that differs from HEAD is left out, since the working tree is its
  /// baseline. A golden this branch changed also needs the commit it was
  /// last changed in before the branch, for the report's diff.
  Future<Map<String, List<String>>> missing(String pathspec) async {
    final context = await _context;
    if (context.fallback != null) return const {};
    final repo = context.repo!;
    final byCommit = <String, List<String>>{};
    Future<void> need(String golden, {String? at}) async {
      final commit = await repo.lastCommitOf(golden, at: at);
      if (commit == null) return;
      final inPackage = golden.substring(repo.packagePrefix.length);
      if (context.store!.baseline(commit, context.unit, inPackage) != null) {
        return;
      }
      (byCommit[commit] ??= []).add(golden);
    }

    for (final golden in await goldens(pathspec)) {
      if (!context.dirty.contains(golden)) await need(golden);
      if (context.changed.contains(golden)) await need(golden, at: context.base);
    }
    return byCommit;
  }

  /// How this branch changed the golden at [path], or null when it did not.
  ///
  /// Never throws: the report's diff is information, so a base that cannot be
  /// built here falls back to the png committed there.
  Future<BranchChange?> branchChange(String path) async {
    final context = await _context;
    final repo = context.repo;
    if (repo == null) return null;
    final relative = _relativeTo(repo.topLevel, path);
    if (relative == null || !context.changed.contains(relative)) return null;
    final base = context.base;
    final commit = await repo.lastCommitOf(relative, at: base);
    if (commit == null) {
      return BranchChange(base: base, image: null, was: 'new on this branch');
    }
    final inPackage = relative.substring(repo.packagePrefix.length);
    try {
      await build(commit);
      final file = context.store!.baseline(commit, context.unit, inPackage);
      if (file != null) {
        return BranchChange(
          base: base,
          image: await file.readAsBytes(),
          was: "this machine's render of ${_short(commit)}, before the branch",
        );
      }
    } on Object {
      // A base that does not build here: the png committed there instead.
    }
    return BranchChange(
      base: base,
      image: await repo.show(commit, relative),
      was: 'the png committed at ${_short(commit)}, before the branch, '
          'perhaps rendered on another machine',
    );
  }

  /// Builds [commit]'s baselines, once.
  Future<void> build(String commit) async {
    final context = await _context;
    final store = context.store;
    if (store == null) return;
    await (_fills[commit] ??= store.fill(
      commit,
      context.unit,
      (into) => context.builder!.build(commit, into),
    ));
  }

  /// The tracked goldens matching [pathspec], repo-relative.
  Future<List<String>> goldens(String pathspec) async {
    final context = await _context;
    final repo = context.repo;
    if (repo == null) return const [];
    return repo.trackedFiles(':(glob)${repo.packagePrefix}$pathspec');
  }

  /// The goldens matching [pathspec] that this branch changed since its
  /// merge-base with the default branch, repo-relative.
  Future<List<String>> changedByBranch(String pathspec) async {
    final context = await _context;
    final repo = context.repo;
    if (repo == null) return const [];
    final matching = await repo.run([
      'ls-files', '--cached', '--others', '--exclude-standard', '--',
      ':(glob)${repo.packagePrefix}$pathspec',
    ]);
    return [
      for (final line in (matching ?? '').split('\n'))
        if (context.changed.contains(line)) line,
    ]..sort();
  }

  /// The commit this branch is measured from, or null outside a repository.
  Future<String?> get base async => (await _context).repo == null
      ? null
      : (await _context).base;

  /// The folder this machine's baselines are in, or null when they are not
  /// used.
  Future<Directory?> get machineDir async => (await _context).store?.machineDir;

  /// Why machine baselines are not used, or null when they are.
  Future<String?> get fallbackReason async => (await _context).fallback;

  Future<_Context> _open() async {
    if (environment[childEnvironmentVariable] == '1') {
      return const _Context.fallback('this run is itself building baselines');
    }
    final key = this.key;
    if (key.engineRevision == null) {
      // Without the engine in the key, an engine update would reuse
      // baselines it did not render.
      return const _Context.fallback(
        'the Flutter SDK, and so the engine revision, could not be found',
      );
    }
    final repo = await GitRepo.open(packageDir);
    if (repo == null) {
      return const _Context.fallback('the package is not in a git repository');
    }
    final base = await repo.branchBase(
      baseRef: environment[baseEnvironmentVariable],
    );
    if (base == null) {
      return const _Context.fallback('the repository has no commit yet');
    }
    final root = _cacheRoot ?? defaultCacheRoot(environment: environment);
    final store = BaselineStore.open(root, key);
    final flutterRoot = MachineKey.flutterRoot(environment: environment);
    final prefix = repo.packagePrefix;
    return _Context(
      repo: repo,
      base: base,
      changed: await repo.changedSince(base),
      dirty: await repo.dirty(),
      store: store,
      unit: prefix.isEmpty
          ? 'root'
          : prefix.substring(0, prefix.length - 1).replaceAll('/', '__'),
      builder: BaselineBuilder(
        repo: repo,
        flutterRoot: flutterRoot!,
        environment: environment,
        goldenTestMarker: goldenTestMarker,
        runProcess: _runProcess,
      ),
    );
  }

  String? _relativeTo(String top, String path) {
    final absolute = path.startsWith('/') || path.contains(':\\')
        ? path
        : '$packageDir/$path';
    final real = _real(absolute);
    final realTop = _real(top);
    if (!real.startsWith('$realTop/')) return null;
    return real.substring(realTop.length + 1);
  }
}

// The path with symbolic links resolved, for a file that may not exist yet:
// git prints /private/tmp where a test's path says /tmp.
String _real(String path) {
  final file = File(path);
  if (file.existsSync()) return file.resolveSymbolicLinksSync();
  final dir = Directory(path);
  if (dir.existsSync()) return dir.resolveSymbolicLinksSync();
  final cut = path.lastIndexOf('/');
  if (cut <= 0) return path;
  return '${_real(path.substring(0, cut))}${path.substring(cut)}';
}

String _short(String sha) => sha.length > 10 ? sha.substring(0, 10) : sha;

class _Context {
  const _Context({
    required this.repo,
    required this.base,
    required this.changed,
    required this.dirty,
    required this.store,
    required this.unit,
    required this.builder,
  }) : fallback = null;

  const _Context.fallback(String this.fallback)
    : repo = null,
      base = '',
      changed = const {},
      dirty = const {},
      store = null,
      unit = '',
      builder = null;

  final String? fallback;
  final GitRepo? repo;
  final String base;
  final Set<String> changed;
  final Set<String> dirty;
  final BaselineStore? store;
  final String unit;
  final BaselineBuilder? builder;
}
