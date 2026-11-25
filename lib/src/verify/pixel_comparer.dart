/// Two images to compare pixel by pixel, and where to write their diff.
final class ImagePair {
  /// [committed] against [rendered], the diff images into [diffDir].
  const new({
    required this.committed,
    required this.rendered,
    required this.diffDir,
  });

  /// The committed png's file.
  final String committed;

  /// The render's file.
  final String rendered;

  /// The folder the diff images go in, when the two differ.
  final String diffDir;

  /// The pair as the compare's manifest records it.
  Map<String, String> toJson() => {
    'committed': committed,
    'rendered': rendered,
    'diffDir': diffDir,
  };
}

/// How the two images of one [ImagePair] compared.
final class PixelVerdict {
  /// Equal pixels.
  const new same() : difference = null, diffs = const [];

  /// Different pixels: [difference] in words, [diffs] the images of it.
  const new different(String this.difference, this.diffs);

  /// How they differ, or null when they do not.
  final String? difference;

  /// The images written: the diffs, or, when the sizes differ, both
  /// images as Flutter read them. Empty when they do not differ.
  final List<String> diffs;

  /// Whether every pixel is equal.
  bool get isSame => difference == null;
}

/// The compare could not run at all, so no pair has a verdict.
final class PixelCompareFailure implements Exception {
  /// The compare failed with [message]; [output] is the tail of what it
  /// printed.
  const new(this.message, {this.output = ''});

  /// What failed, in a sentence.
  final String message;

  /// The tail of the compare's output.
  final String output;

  @override
  String toString() =>
      output.isEmpty ? message : '$message\n${output.trimRight()}';
}

/// Compares images pixel by pixel, as `matchesGoldenFile` does: the one
/// seam between `verify` and a Flutter test binding.
abstract interface class PixelComparer {
  /// One verdict per pair of [pairs], in order. Writes the diff images of
  /// a pair that differs into its [ImagePair.diffDir].
  ///
  /// Throws [PixelCompareFailure] when the compare could not run.
  Future<List<PixelVerdict>> compare(List<ImagePair> pairs);
}
