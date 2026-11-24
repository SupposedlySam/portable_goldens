/// A commit could not be checked out (a shallow clone, say). The comparator
/// then compares with the committed image instead.
final class CheckoutUnavailable implements Exception {
  /// [commit] could not be checked out, and git said [reason].
  const new(this.commit, this.reason);

  /// The commit.
  final String commit;

  /// What git printed.
  final String reason;

  @override
  String toString() => 'commit $commit could not be checked out: $reason';
}
