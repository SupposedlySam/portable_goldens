import 'package:portable_goldens/src/store/build_failure.dart';

/// What `verify` found for one committed golden: whether its png is what
/// its own commit draws on this machine.
sealed class GoldenCheck {
  const new(this.golden);

  /// The golden, relative to the package.
  final String golden;

  /// Whether this check fails `verify`.
  ///
  /// Anything that is not a verified png fails it, a golden that could not
  /// be checked included: a check that did not run is not a pass.
  bool get isFailure;

  /// The check as json, for tools: the golden, a `result` naming the kind,
  /// and that kind's details.
  Map<String, Object?> toJson() => {'golden': golden, ..._details};

  Map<String, Object?> get _details;
}

/// The committed png is, pixel for pixel, this machine's render of the
/// commit that last changed it.
final class Verified extends GoldenCheck {
  /// [golden] matches [commit]'s render.
  const new(super.golden, this.commit);

  /// The commit that last changed the png.
  final String commit;

  @override
  bool get isFailure => false;

  @override
  Map<String, Object?> get _details => {'result': 'verified', 'commit': commit};
}

/// The committed png is not what its commit draws here.
///
/// On the machine that rendered the png, that means the commit cannot draw
/// its own png: the png was committed before its code, or with part of it.
final class Mismatch extends GoldenCheck {
  /// [golden] as [commit] has it ([committed]) differs from [rendered], that
  /// commit's render here; [diffs] are the images of the difference.
  const new(
    super.golden,
    this.commit, {
    required this.committed,
    required this.rendered,
    required this.diffs,
    required this.difference,
  });

  /// The commit that last changed the png.
  final String commit;

  /// A copy of the committed png.
  final String committed;

  /// A copy of the commit's render on this machine.
  final String rendered;

  /// The diff images, where the compare wrote them; when the sizes differ,
  /// both images as Flutter read them instead.
  final List<String> diffs;

  /// How they differ, in Flutter's words, e.g. `Pixel test failed, 0.12%,
  /// 31px diff detected.`
  final String difference;

  @override
  bool get isFailure => true;

  @override
  Map<String, Object?> get _details => {
    'result': 'mismatch',
    'commit': commit,
    'difference': difference,
    'committed': committed,
    'rendered': rendered,
    'diffs': diffs,
  };
}

/// The commit that last changed the png did not build here, so there is no
/// render to check it against.
final class Unbuilt extends GoldenCheck {
  /// [golden]'s commit failed to build, with [failure].
  const new(super.golden, this.failure);

  /// What failed.
  final BuildFailure failure;

  @override
  bool get isFailure => true;

  @override
  Map<String, Object?> get _details => {
    'result': 'unbuilt',
    'failure': failure.toJson(),
  };
}

/// The png could not be checked, for [reason].
final class Unverifiable extends GoldenCheck {
  /// [golden] was not checked, for [reason].
  const new(super.golden, this.reason);

  /// Why, in a phrase.
  final String reason;

  @override
  bool get isFailure => true;

  @override
  Map<String, Object?> get _details => {
    'result': 'unverifiable',
    'reason': reason,
  };
}

/// The png is new and not committed: there is no commit to check it
/// against yet, and nothing wrong with it.
final class Uncommitted extends GoldenCheck {
  /// [golden] has no commit.
  const new(super.golden);

  @override
  bool get isFailure => false;

  @override
  Map<String, Object?> get _details => {'result': 'uncommitted'};
}
