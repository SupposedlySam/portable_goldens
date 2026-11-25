import 'dart:io';

import 'package:portable_goldens/src/git/commit_reachability.dart';
import 'package:portable_goldens/src/prune/cache_inventory.dart';
import 'package:portable_goldens/src/prune/prune_policy.dart';
import 'package:portable_goldens/src/store/file_entries.dart';

/// What happened to one thing prune chose to remove.
enum PruneOutcome {
  /// It is gone.
  removed,

  /// It would have gone: a dry run.
  wouldRemove,

  /// It was left alone: a build holds its lock.
  inUse,

  /// Removing it failed part way; [PruneAction.error] says how.
  failed,
}

/// One thing prune chose to remove, and what happened to it.
final class PruneAction {
  /// [label] of [bytes], chosen for [reason], with [outcome].
  const new({
    required this.label,
    required this.bytes,
    required this.reason,
    required this.outcome,
    this.error,
  });

  /// What it is, relative to the cache: `<key id>/<commit>/<unit>`, or
  /// `<key id>` for a machine folder.
  final String label;

  /// The bytes it took.
  final int bytes;

  /// Why it was chosen ([PrunePolicy]).
  final String reason;

  /// What happened.
  final PruneOutcome outcome;

  /// Why removing it failed, when it did.
  final String? error;

  /// Whether its bytes are, or in a dry run would be, freed.
  bool get frees =>
      outcome == PruneOutcome.removed || outcome == PruneOutcome.wouldRemove;
}

/// What one prune did.
final class PruneResult {
  /// [actions] taken, [kept] units kept, of which [keptAbsent] are of
  /// commits the repository does not have and [keptUnknown] of commits
  /// whose reachability is unknown.
  const new({
    required this.actions,
    required this.kept,
    required this.keptAbsent,
    required this.keptUnknown,
  });

  /// Everything prune chose to remove, units first, then machine folders.
  final List<PruneAction> actions;

  /// The units kept.
  final int kept;

  /// The kept units whose commit this repository does not have, which only
  /// age could remove.
  final int keptAbsent;

  /// The kept units whose commit git could not judge, or that were judged
  /// with no repository, which only age could remove.
  final int keptUnknown;

  /// The bytes freed, or in a dry run that would be.
  int get freed => actions
      .where((action) => action.frees)
      .fold(0, (sum, action) => sum + action.bytes);

  /// Whether something chosen could not be removed.
  bool get hasFailures => actions.any((a) => a.outcome == PruneOutcome.failed);
}

/// Removes from the cache what [policy] says has gone, asking
/// [reachability] about each commit.
final class CachePruner {
  /// A prune by [policy]; [dryRun] removes nothing and says what it would.
  const new({
    required this.policy,
    required this.reachability,
    this.dryRun = false,
  });

  /// What decides.
  final PrunePolicy policy;

  /// Whether each commit is reachable here.
  final CommitReachability reachability;

  /// Whether nothing is removed.
  final bool dryRun;

  /// Prunes what [inventory] found.
  Future<PruneResult> prune(CacheInventory inventory) async {
    final units = <PruneAction>[];
    final machines = <PruneAction>[];
    var kept = 0;
    var keptAbsent = 0;
    var keptUnknown = 0;
    for (final machine in inventory.machines) {
      var left = machine.units.length;
      for (final unit in machine.units) {
        final reach = await reachability.reachabilityOf(unit.commit);
        final reason = policy.reasonToRemove(unit.lastUsed, reach);
        if (reason == null) {
          kept++;
          if (reach == Reachability.absent) keptAbsent++;
          if (reach == Reachability.unknown) keptUnknown++;
          continue;
        }
        final action = await _removeUnit(unit, reason);
        units.add(action);
        if (action.frees) left--;
      }
      if (left == 0 && !machine.hasForeign) {
        if (policy.reasonToRemoveMachine(machine.lastUsed) case final reason?) {
          machines.add(await _removeMachine(machine, reason));
        }
      }
    }
    return PruneResult(
      actions: [...units, ...machines],
      kept: kept,
      keptAbsent: keptAbsent,
      keptUnknown: keptUnknown,
    );
  }

  Future<PruneAction> _removeUnit(CachedUnit unit, String reason) => _remove(
    label: unit.label,
    bytes: unit.bytes,
    reason: reason,
    remove: () async => await unit.baselines.remove()
        ? PruneOutcome.removed
        : PruneOutcome.inUse,
  );

  // The folder holds its manifest now, and empty commit folders at most.
  // Its last use was read from the manifest just now, after its units went,
  // so a test process that opened the store while they were being removed
  // keeps it. One that opens it in the instant before the delete builds
  // what it needs into a folder made again with no manifest, which the
  // inventory leaves alone and the next open gives one: the cost is a
  // rebuild, as for anything prune removes.
  Future<PruneAction> _removeMachine(CachedMachine machine, String reason) =>
      _remove(
        label: machine.id,
        bytes: bytesUnder(machine.dir.path),
        reason: reason,
        remove: () async {
          machine.dir.deleteSync(recursive: true);
          return PruneOutcome.removed;
        },
      );

  Future<PruneAction> _remove({
    required String label,
    required int bytes,
    required String reason,
    required Future<PruneOutcome> Function() remove,
  }) async {
    var outcome = PruneOutcome.wouldRemove;
    String? error;
    if (!dryRun) {
      try {
        outcome = await remove();
      } on FileSystemException catch (failure) {
        outcome = PruneOutcome.failed;
        error = '$failure';
      }
    }
    return PruneAction(
      label: label,
      bytes: bytes,
      reason: reason,
      outcome: outcome,
      error: error,
    );
  }
}
