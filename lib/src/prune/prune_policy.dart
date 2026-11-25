import 'package:portable_goldens/src/git/commit_reachability.dart';

/// Why baselines go, or null when they stay.
///
/// Baselines are a cache: removing ones still needed costs a rebuild, never
/// a wrong result. Two rules, and use protects from both:
///
/// - **Unused** for [unusedFor]: whatever the commit, in any repository,
///   for any machine key. A key from before an OS or SDK update is never
///   used again, so its baselines age out by this rule; one another project
///   on another Flutter SDK still uses stays.
/// - **Unreachable** here and unused for [unreachableFor]: rebased, amended
///   or squashed away. Only for a commit this repository has: one it does
///   not have may be another repository's, the cache being shared, and so is
///   judged by age alone. The short wait keeps baselines a test may be
///   reading right now, and ones another clone of the repository, with
///   other branches, used today.
final class PrunePolicy {
  /// Removes what was unused for [unusedFor], or unreachable and unused for
  /// [unreachableFor], as of [now].
  const new({
    required this.unusedFor,
    required this.now,
    this.unreachableFor = const Duration(days: 1),
  });

  /// How long unused baselines are kept.
  final Duration unusedFor;

  /// How long unused baselines of an unreachable commit are kept.
  final Duration unreachableFor;

  /// The time judged at.
  final DateTime now;

  /// Why baselines last used at [lastUsed], of a commit that is
  /// [reachability] here, go; null when they stay. Nothing on disk
  /// ([lastUsed] null) has nothing to remove.
  String? reasonToRemove(DateTime? lastUsed, Reachability reachability) {
    if (lastUsed == null) return null;
    final unused = now.difference(lastUsed);
    if (unused >= unusedFor) return 'unused for ${_days(unused)}';
    if (reachability == Reachability.unreachable && unused >= unreachableFor) {
      return 'no branch, tag or checkout here has the commit; unused for '
          '${_days(unused)}';
    }
    return null;
  }

  /// Why a machine folder last opened at [lastUsed], with nothing left in
  /// it, goes; null when it stays.
  String? reasonToRemoveMachine(DateTime? lastUsed) {
    if (lastUsed == null) return null;
    final unused = now.difference(lastUsed);
    return unused >= unusedFor
        ? 'no baselines left, and not opened for ${_days(unused)}'
        : null;
  }

  /// Every rule, in a sentence, for prune's first line.
  String get described =>
      'removing what was unused for ${_days(unusedFor)}, or for '
      '${_days(unreachableFor)} when no branch, tag or checkout here has its '
      'commit';
}

String _days(Duration duration) {
  final days = duration.inDays;
  return days == 1 ? 'a day' : '$days days';
}
