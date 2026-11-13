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

/// The golden is changed by this branch, so the render is what it should be.
///
/// Its committed png differs from the branch's merge-base: changed on this
/// branch, uncommitted, or new. The change is the point of the work, so no
/// older render can be its baseline; the working tree's own render is, and the
/// test passes. That comparison is of a render with itself, so it says
/// nothing; the comparator records the golden, with its diff against the
/// committed image, for the `report` command to list as changed by this
/// branch.
class BranchChangedBaseline extends GoldenBaseline {
  /// The branch changed the golden since [base].
  const BranchChangedBaseline(this.base);

  /// The commit the branch is measured from.
  final String base;
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
    if (context.changed.contains(relative)) {
      return BranchChangedBaseline(context.base);
    }
    final commit = await repo.lastCommitOf(relative);
    if (commit == null) {
      return const CommittedBaseline('no commit has the golden');
    }
    final unit = context.unit;
    final inPackage = relative.substring(repo.packagePrefix.length);
    final store = context.store!;
    try {
      await (_fills[commit] ??= store.fill(
        commit,
        unit,
        (into) => context.builder!.build(commit, into),
      ));
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
  /// Goldens changed by this branch are left out: the working tree is their
  /// baseline, so nothing is built for them.
  Future<Map<String, List<String>>> missing(String pathspec) async {
    final context = await _context;
    if (context.fallback != null) return const {};
    final repo = context.repo!;
    final byCommit = <String, List<String>>{};
    for (final golden in await goldens(pathspec)) {
      if (context.changed.contains(golden)) continue;
      final commit = await repo.lastCommitOf(golden);
      if (commit == null) continue;
      final inPackage = golden.substring(repo.packagePrefix.length);
      if (context.store!.baseline(commit, context.unit, inPackage) != null) {
        continue;
      }
      (byCommit[commit] ??= []).add(golden);
    }
    return byCommit;
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

  /// The goldens matching [pathspec] that this branch changed, repo-relative.
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

class _Context {
  const _Context({
    required this.repo,
    required this.base,
    required this.changed,
    required this.store,
    required this.unit,
    required this.builder,
  }) : fallback = null;

  const _Context.fallback(String this.fallback)
    : repo = null,
      base = '',
      changed = const {},
      store = null,
      unit = '',
      builder = null;

  final String? fallback;
  final GitRepo? repo;
  final String base;
  final Set<String> changed;
  final BaselineStore? store;
  final String unit;
  final BaselineBuilder? builder;
}
