import 'dart:io';

/// What one golden is compared against.
sealed class GoldenBaseline {
  const new();
}

/// This machine's render of the commit that last changed the golden.
final class MachineBaseline extends GoldenBaseline {
  /// [file] is [commit]'s render on the machine [keyId] names.
  const new(this.file, this.commit, this.keyId);

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
final class WorkingTreeBaseline extends GoldenBaseline {
  /// The png in the working tree.
  const new();
}

/// The committed image itself, as a plain `LocalFileComparator` would use.
final class CommittedBaseline extends GoldenBaseline {
  /// Machine baselines do not apply, for [reason].
  const new(this.reason);

  /// Why, in a phrase.
  final String reason;
}
