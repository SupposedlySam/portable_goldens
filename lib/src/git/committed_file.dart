import 'dart:convert';

/// A file as a commit has it, read through the filters its attributes name,
/// as a checkout would write it: the bytes, or why they are unknown here.
sealed class CommittedFile {
  /// A file as git gave it.
  const new();

  /// [bytes] as git gave them: an [LfsPointer] when they are one, which a
  /// filter that is not installed, or not required, hands back unchanged.
  factory of(List<int> bytes) =>
      LfsPointer.parse(bytes) ?? CommittedBytes(bytes);
}

/// The file's own bytes.
final class CommittedBytes extends CommittedFile {
  /// The file is [bytes].
  const new(this.bytes);

  /// What a checkout of the commit writes for the file.
  final List<int> bytes;
}

/// A committed file whose bytes are not known here. Never compared: an
/// unknown is not an image, and a compare with one would fail on a
/// difference that is not in the pixels.
sealed class UnknownFile extends CommittedFile {
  /// A file whose bytes are unknown.
  const new();

  /// Why the bytes are unknown, in words, for a report.
  String get why;
}

/// A Git LFS pointer: the file is in LFS, and its object did not reach git's
/// answer, because `git lfs` is not installed for this repository.
///
/// The pointer format is [the spec](https://github.com/git-lfs/git-lfs/blob/main/docs/spec.md):
/// a text file under 1024 bytes whose first line is `version` and the spec's
/// URL, then `oid sha256:<hex>` and `size <bytes>`.
final class LfsPointer extends UnknownFile {
  /// A pointer to the object [oid], of [size] bytes.
  const new({required this.oid, required this.size});

  /// The pointer in [bytes], or null when they are not one.
  ///
  /// The version line decides, with either URL the spec has had; [oid] and
  /// [size] are null when the pointer lacks them, since a file that claims
  /// to be a pointer is no image either way.
  static LfsPointer? parse(List<int> bytes) {
    if (bytes.length >= _maxSize) return null;
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return null;
    }
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || !_versions.contains(lines.first)) return null;
    String? valueOf(String key) => [
      for (final line in lines.skip(1))
        if (line.startsWith('$key ')) line.substring(key.length + 1),
    ].firstOrNull;
    return LfsPointer(
      oid: valueOf('oid'),
      size: int.tryParse(valueOf('size') ?? ''),
    );
  }

  static const _maxSize = 1024;
  static const _versions = {
    'version https://git-lfs.github.com/spec/v1',
    'version https://hawser.github.com/spec/v1',
  };

  /// The object's id, `sha256:` and its hex digest.
  final String? oid;

  /// The object's size in bytes.
  final int? size;

  @override
  String get why =>
      'it is a Git LFS pointer${size == null ? '' : ' to $size bytes'}, '
      'not the image: install Git LFS (`git lfs install`) and fetch its '
      'objects (`git lfs pull`)';
}

/// A committed file git could not read: a required filter failed, such as
/// `git lfs` without the object and no way to download it.
final class UnreadFile extends UnknownFile {
  /// Git failed to read the file, and said [error].
  const new(this.error);

  /// What git said.
  final String error;

  @override
  String get why => 'git could not read it: $error';
}
