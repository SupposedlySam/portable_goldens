import 'dart:io';

import 'package:portable_goldens/src/build/baseline_builder.dart';
import 'package:portable_goldens/src/git/git_repo.dart';
import 'package:portable_goldens/src/machine/flutter_sdk.dart';
import 'package:portable_goldens/src/machine/machine_key.dart';
import 'package:portable_goldens/src/process/process_runner.dart';
import 'package:portable_goldens/src/session/branch_change.dart';
import 'package:portable_goldens/src/session/golden_baseline.dart';
import 'package:portable_goldens/src/session/goldens_session.dart';
import 'package:portable_goldens/src/store/baseline_store.dart';
import 'package:portable_goldens/src/store/build_failure.dart';
import 'package:portable_goldens/src/store/cache_root.dart';

/// The environment variable that names the ref a branch is measured from, in
/// place of the remote's default branch.
const baseEnvironmentVariable = 'PORTABLE_GOLDENS_BASE';

/// Finds the baseline of each golden of one package, building what is
/// missing. One per test process, shared by every golden in it.
///
/// It looks once, on the first question: whether this run may use machine
/// baselines at all, and if so, the repository, the branch and this
/// machine's store. Every question after that goes to what it found.
final class MachineGoldens {
  /// The baselines of the package at [packageDir].
  ///
  /// The rest is for tests: a fake `key` stands in for an OS update, a
  /// `runProcess` for `flutter` and `git`.
  new({
    required this.packageDir,
    Map<String, String>? environment,
    this._key,
    this._cacheRoot,
    this.goldenTestMarker = defaultGoldenTestMarker,
    this._runProcess = Process.run,
  }) : environment = environment ?? Platform.environment;

  /// The package's folder.
  final String packageDir;

  /// The environment this runs in.
  final Map<String, String> environment;

  /// A commit's test file builds baselines when its source contains this.
  final String goldenTestMarker;

  final MachineKey? _key;
  final String? _cacheRoot;
  final ProcessRunner _runProcess;

  late final Future<GoldensSession> _session = _open();

  /// The key this machine's baselines are filed under.
  late final MachineKey key =
      _key ?? MachineKey.current(environment: environment);

  /// The baseline of the golden at [path] (absolute, or relative to the
  /// package).
  ///
  /// Throws [BuildFailure] when the baseline had to be built and the build
  /// failed, or ran and did not render this golden.
  Future<GoldenBaseline> baselineFor(String path) =>
      _session.then((s) => s.baselineFor(path));

  /// The goldens matching [pathspec] (a git pathspec, relative to the
  /// package) whose baselines are missing on this machine, by the commit
  /// that last changed each.
  Future<Map<String, List<String>>> missing(String pathspec) =>
      _session.then((s) => s.missing(pathspec));

  /// How this branch changed the golden at [path], or null when it did not.
  /// Never throws.
  Future<BranchChange?> branchChange(String path) =>
      _session.then((s) => s.branchChange(path));

  /// Builds [commit]'s baselines, once.
  Future<void> build(String commit) => _session.then((s) => s.build(commit));

  /// The tracked goldens matching [pathspec], repo-relative.
  Future<List<String>> goldens(String pathspec) =>
      _session.then((s) => s.goldens(pathspec));

  /// The goldens matching [pathspec] that this branch changed since its
  /// merge-base with the default branch, relative to the package and sorted:
  /// the form the report records a golden in.
  Future<List<String>> changedByBranch(String pathspec) =>
      _session.then((s) => s.changedByBranch(pathspec));

  /// The commit this branch is measured from, or null when machine
  /// baselines are not used.
  Future<String?> get base => _session.then((s) => s.base);

  /// The folder this machine's baselines are in, or null when they are not
  /// used.
  Future<Directory?> get machineDir => _session.then((s) => s.machineDir);

  /// Why machine baselines are not used, or null when they are.
  Future<String?> get fallbackReason => _session.then((s) => s.fallbackReason);

  Future<GoldensSession> _open() async {
    if (environment[childEnvironmentVariable] == '1') {
      return const FallbackSession('this run is itself building baselines');
    }
    final key = this.key;
    if (!key.isComplete) {
      // Without the engine and framework in the key, an update would reuse
      // baselines it did not render.
      return const FallbackSession(
        "the Flutter SDK's engine or framework revision could not be found",
      );
    }
    final sdk = FlutterSdk.current(environment: environment);
    if (sdk == null) {
      return const FallbackSession('the Flutter SDK could not be found');
    }
    final repo = await GitRepo.open(packageDir, runProcess: _runProcess);
    if (repo == null) {
      return const FallbackSession('the package is not in a git repository');
    }
    if (await repo.isShallow()) {
      // The boundary commit would pass for the commit that last changed
      // every older golden, and its render is not what any of them showed.
      return const FallbackSession(
        'the clone is shallow, so the commit that last changed a golden '
        'cannot be found',
      );
    }
    final base = await repo.branchBase(
      baseRef: environment[baseEnvironmentVariable],
    );
    if (base == null) {
      return const FallbackSession('the repository has no commit yet');
    }
    final root = _cacheRoot ?? defaultCacheRoot(environment: environment);
    return ActiveSession(
      repo: repo,
      store: BaselineStore.open(root, key),
      builder: BaselineBuilder(
        repo: repo,
        sdk: sdk,
        environment: environment,
        goldenTestMarker: goldenTestMarker,
        runProcess: _runProcess,
      ),
      base: base,
      changed: await repo.changedSince(base),
      dirty: await repo.dirty(),
    );
  }
}
