import 'package:portable_goldens/src/build/checkout_unavailable.dart';

/// Why a golden is compared with its committed image rather than with this
/// machine's render of it.
///
/// Typed, not a string, because code decides on it: the comparator stays
/// quiet about [SessionFallback.buildingBaselines], which is the design
/// rather than news. It used to recognise that case by a word in the
/// message, so rewording the message would have broken it silently.
///
/// [toString] is [phrase], so a reason reads the same in an interpolation.
sealed class FallbackReason {
  /// The reason as a phrase, to follow "because".
  String get phrase;
}

/// What a reason prints as.
mixin _ReadsAsPhrase implements FallbackReason {
  @override
  String toString() => phrase;
}

/// Machine baselines do not apply to any golden of this test process.
enum SessionFallback with _ReadsAsPhrase implements FallbackReason {
  /// The process is a build's own `flutter test`, rendering baselines.
  buildingBaselines('this run is itself building baselines'),

  /// The key would leave out what renders: an update could reuse baselines
  /// it did not render.
  sdkRevisionUnknown(
    "the Flutter SDK's engine or framework revision could not be found",
  ),

  /// No Flutter SDK to build with.
  sdkNotFound('the Flutter SDK could not be found'),

  /// No git, or no repository around the package.
  notInRepository('the package is not in a git repository'),

  /// The boundary commit would pass for the commit that last changed every
  /// older golden, and its render is not what any of them showed.
  shallowClone(
    'the clone is shallow, so the commit that last changed a golden cannot '
    'be found',
  ),

  /// Nothing to render from.
  noCommit('the repository has no commit yet');

  new(this.phrase);

  @override
  final String phrase;
}

/// Machine baselines apply to the process, but not to this golden.
enum GoldenFallback with _ReadsAsPhrase implements FallbackReason {
  /// The golden's path is not in the package's repository.
  outsideRepository('the golden is outside the repository'),

  /// The golden is in the repository, but not in the package.
  outsidePackage('the golden is outside the package'),

  /// The png is not committed, so no commit has it to render.
  uncommitted('no commit has the golden');

  new(this.phrase);

  @override
  final String phrase;
}

/// The commit that last changed the golden could not be checked out to
/// render it.
final class CheckoutFailed with _ReadsAsPhrase implements FallbackReason {
  /// The checkout failed as [failure] says.
  const new(this.failure);

  /// What failed, and what git said.
  final CheckoutUnavailable failure;

  @override
  String get phrase => '$failure';
}
