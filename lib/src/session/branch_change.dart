/// How this branch changed a golden, for the report: what the png was when
/// the branch left the default branch.
final class BranchChange {
  /// The branch changed the golden since [base]; [image] is what it was
  /// there, described by [was], or null when the golden is new.
  const new({required this.base, required this.image, required this.was});

  /// The commit the branch is measured from.
  final String base;

  /// The golden as it was at [base]: this machine's render where it can be
  /// built, else the png committed there.
  final List<int>? image;

  /// What [image] is, in words.
  final String was;
}
