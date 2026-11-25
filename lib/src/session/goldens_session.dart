import 'dart:io';

import 'package:portable_goldens/src/build/baseline_builder.dart';
import 'package:portable_goldens/src/build/checkout_unavailable.dart';
import 'package:portable_goldens/src/git/committed_file.dart';
import 'package:portable_goldens/src/git/git_repo.dart';
import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/session/branch_change.dart';
import 'package:portable_goldens/src/session/fallback_reason.dart';
import 'package:portable_goldens/src/session/golden_baseline.dart';
import 'package:portable_goldens/src/store/baseline_store.dart';
import 'package:portable_goldens/src/store/build_failure.dart';

/// What one test process knows about one package's goldens, once it has
/// looked: either machine baselines apply ([ActiveSession]) or they do not,
/// for a reason ([FallbackSession]). `MachineGoldens` opens one and hands
/// every question to it, so no question asks which kind it has.
sealed class GoldensSession {
  const new();

  /// The baseline of the golden at [path] (absolute, or relative to the
  /// package).
  Future<GoldenBaseline> baselineFor(String path);

  /// The baseline of the golden at [path] as HEAD has it: [baselineFor],
  /// except that a png the working tree changed since HEAD is still the
  /// render of the commit that last changed it, never the working tree.
  Future<GoldenBaseline> baselineAtHead(String path);

  /// The goldens matching [pathspec] whose baselines are missing here, by
  /// the commit that last changed each; package-relative.
  Future<Map<String, List<String>>> missing(String pathspec);

  /// How this branch changed the golden at [path], or null.
  Future<BranchChange?> branchChange(String path);

  /// Builds [commit]'s baselines, once.
  Future<void> build(String commit);

  /// The tracked goldens matching [pathspec], package-relative.
  Future<List<String>> goldens(String pathspec);

  /// The golden at [path] (absolute, or relative to the package) as
  /// [commit] has it, or null when it has none.
  Future<CommittedFile?> committedImage(String commit, String path);

  /// The goldens matching [pathspec] this branch changed, relative to the
  /// package, sorted.
  Future<List<String>> changedByBranch(String pathspec);

  /// The commit this branch is measured from, or null.
  String? get base;

  /// The folder this machine's baselines are in, or null.
  Directory? get machineDir;

  /// Why machine baselines are not used, or null when they are.
  SessionFallback? get fallbackReason;
}

/// Machine baselines do not apply: every golden is compared with its
/// committed image, and there is nothing to build or report.
final class FallbackSession extends GoldensSession {
  /// Machine baselines do not apply, for [reason].
  const new(this.reason);

  /// Why.
  final SessionFallback reason;

  @override
  Future<GoldenBaseline> baselineFor(String path) async =>
      CommittedBaseline(reason);

  @override
  Future<GoldenBaseline> baselineAtHead(String path) async =>
      CommittedBaseline(reason);

  @override
  Future<Map<String, List<String>>> missing(String pathspec) async => const {};

  @override
  Future<BranchChange?> branchChange(String path) async => null;

  @override
  Future<void> build(String commit) async {}

  @override
  Future<List<String>> goldens(String pathspec) async => const [];

  @override
  Future<CommittedFile?> committedImage(String commit, String path) async =>
      null;

  @override
  Future<List<String>> changedByBranch(String pathspec) async => const [];

  @override
  String? get base => null;

  @override
  Directory? get machineDir => null;

  @override
  SessionFallback get fallbackReason => reason;
}

/// Machine baselines apply: a package in a full clone, on a machine whose
/// key is known.
final class ActiveSession extends GoldensSession {
  /// The session of [repo]'s package, measured from [base].
  new({
    required this.repo,
    required this.store,
    required this.builder,
    required this.base,
    required this.changed,
    required this.dirty,
  });

  /// The repository the package is in.
  final GitRepo repo;

  /// This machine's baselines.
  final BaselineStore store;

  /// What renders a commit's baselines.
  final BaselineBuilder builder;

  @override
  final String base;

  /// The repo-relative paths this branch changed since [base], uncommitted
  /// changes included.
  final Set<String> changed;

  /// The repo-relative paths that differ from HEAD.
  final Set<String> dirty;

  final _fills = <String, Future<void>>{};

  // The package's folder in the cache, apart from baselines built with
  // other setup steps.
  String get _unit => builder.setup.unitOf(repo.location.unit);

  @override
  Directory get machineDir => store.machineDir;

  @override
  SessionFallback? get fallbackReason => null;

  /// Throws [BuildFailure] when the baseline had to be built and the build
  /// failed, or ran and did not render this golden.
  @override
  Future<GoldenBaseline> baselineFor(String path) =>
      _baseline(path, workingTree: true);

  /// Throws [BuildFailure] as [baselineFor] does.
  @override
  Future<GoldenBaseline> baselineAtHead(String path) =>
      _baseline(path, workingTree: false);

  // [workingTree]: whether a png that differs from HEAD is its own baseline.
  Future<GoldenBaseline> _baseline(
    String path, {
    required bool workingTree,
  }) async {
    final relative = repo.location.repoPathOf(path);
    if (relative == null) {
      return const CommittedBaseline(GoldenFallback.outsideRepository);
    }
    final inPackage = repo.location.packagePath(relative);
    if (inPackage == null) {
      return const CommittedBaseline(GoldenFallback.outsidePackage);
    }
    if (workingTree && dirty.contains(relative)) {
      return const WorkingTreeBaseline();
    }
    final commit = await repo.lastCommitOf(relative);
    if (commit == null) {
      return const CommittedBaseline(GoldenFallback.uncommitted);
    }
    try {
      await build(commit);
    } on CheckoutUnavailable catch (unavailable) {
      return CommittedBaseline(CheckoutFailed(unavailable));
    }
    final baselines = store.at(commit, _unit);
    if (baselines.baseline(inPackage) case final file?) {
      return MachineBaseline(file, commit, store.key.id);
    }
    throw BuildFailure(
      commit: commit,
      command: baselines.command ?? '(not recorded)',
      message:
          'its golden tests ran on this machine and did not write '
          '$inPackage. Is the test that draws it in a file whose source '
          'contains "${builder.goldenTestMarker}"?',
    );
  }

  /// A png that differs from HEAD is left out, since the working tree is its
  /// baseline. A golden this branch changed also needs the commit it was
  /// last changed in before the branch, for the report's diff.
  @override
  Future<Map<String, List<String>>> missing(String pathspec) async {
    final byCommit = <String, List<String>>{};
    Future<void> need(String golden, String inPackage, {String? at}) async {
      final commit = await repo.lastCommitOf(golden, at: at);
      if (commit == null) return;
      if (store.at(commit, _unit).baseline(inPackage) != null) return;
      final paths = byCommit[commit] ??= [];
      if (!paths.contains(inPackage)) paths.add(inPackage);
    }

    for (final golden in await _tracked(pathspec)) {
      final inPackage = repo.location.packagePath(golden);
      if (inPackage == null) continue;
      if (!dirty.contains(golden)) await need(golden, inPackage);
      if (changed.contains(golden)) await need(golden, inPackage, at: base);
    }
    return byCommit;
  }

  /// Never throws: the report's diff is information, so a base that cannot
  /// be built here falls back to the png committed there.
  @override
  Future<BranchChange?> branchChange(String path) async {
    final relative = repo.location.repoPathOf(path);
    if (relative == null || !changed.contains(relative)) return null;
    final commit = await repo.lastCommitOf(relative, at: base);
    if (commit == null) {
      return BranchChange(base: base, image: null, was: 'new on this branch');
    }
    if (await _renderedBefore(commit, relative) case final image?) {
      return BranchChange(
        base: base,
        image: image,
        was: "this machine's render of ${shortSha(commit)}, before the branch",
      );
    }
    final committed =
        'the png committed at ${shortSha(commit)}, before the '
        'branch';
    return switch (await repo.show(commit, relative)) {
      CommittedBytes(:final bytes) => BranchChange(
        base: base,
        image: bytes,
        was: '$committed, perhaps rendered on another machine',
      ),
      final UnknownFile unknown => BranchChange(
        base: base,
        image: null,
        was: 'nothing: $committed is unknown here, because ${unknown.why}',
      ),
      // lastCommitOf named the commit that changed the path; a commit that
      // deleted it has none.
      null => BranchChange(
        base: base,
        image: null,
        was: 'nothing: $committed is not there',
      ),
    };
  }

  // This machine's render of [relative] at [commit], or null when it does
  // not build here.
  Future<List<int>?> _renderedBefore(String commit, String relative) async {
    final inPackage = repo.location.packagePath(relative);
    if (inPackage == null) return null;
    try {
      await build(commit);
      return await store.at(commit, _unit).baseline(inPackage)?.readAsBytes();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> build(String commit) => _fills[commit] ??= store
      .at(commit, _unit)
      .fill((into) => builder.build(commit, into));

  @override
  Future<List<String>> goldens(String pathspec) async => [
    for (final golden in await _tracked(pathspec))
      ?repo.location.packagePath(golden),
  ];

  @override
  Future<CommittedFile?> committedImage(String commit, String path) async {
    final relative = repo.location.repoPathOf(path);
    return relative == null ? null : await repo.show(commit, relative);
  }

  // The tracked goldens matching [pathspec], repo-relative, as git asks.
  Future<List<String>> _tracked(String pathspec) =>
      repo.trackedFiles(repo.location.pathspec(pathspec));

  @override
  Future<List<String>> changedByBranch(String pathspec) async => [
    for (final path in await repo.workingFiles(
      repo.location.pathspec(pathspec),
    ))
      if (changed.contains(path)) ?repo.location.packagePath(path),
  ]..sort();
}
