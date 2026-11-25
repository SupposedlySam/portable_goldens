import 'dart:io';

/// How an OS writes a path, and the one form this package compares paths in:
/// segments joined by `/`, as git prints them on every OS.
///
/// Dart's file API takes `/` on Windows too, so a path this package builds
/// works as it is. What it cannot do is compare: `Directory.listSync`,
/// `resolveSymbolicLinksSync` and `Uri.toFilePath` return `\` on Windows,
/// so a path from one of them never starts with `C:/repo/`, and a golden
/// inside the package looked as if it were outside. Every comparison of a
/// path with a folder goes through [relative], so it is written once.
enum PathStyle {
  /// macOS and Linux: `/` only, and case matters.
  posix,

  /// Windows: `\` or `/`, a drive letter or a `\\server\share` root, and
  /// case does not matter.
  windows;

  /// The style of the OS this runs on.
  static PathStyle get current => Platform.isWindows ? windows : posix;

  static final _drive = RegExp(r'^[A-Za-z]:[\\/]');

  /// [path] with its segments joined by `/`.
  String portable(String path) => switch (this) {
    posix => path,
    windows => path.replaceAll(r'\', '/'),
  };

  /// Whether [path] is absolute, rather than relative to some folder.
  bool isAbsolute(String path) => switch (this) {
    posix => path.startsWith('/'),
    windows =>
      _drive.hasMatch(path) || path.startsWith(r'\\') || path.startsWith('//'),
  };

  /// [path] relative to [dir], with `/` between segments: empty when it is
  /// [dir] itself, null when it is outside it.
  ///
  /// Both are absolute, or both are relative to the same folder; [dir] may
  /// end in a separator or not. On [windows] the comparison ignores the case
  /// of ASCII letters, as NTFS does by default. Other letters must match
  /// exactly, so a path differing in their case is called outside, which
  /// falls back to the committed image rather than comparing a wrong one.
  String? relative(String dir, String path) {
    final base = _withSlash(portable(dir));
    final full = portable(path);
    if (_same(full, base) || _same('$full/', base)) return '';
    if (full.length <= base.length) return null;
    if (!_same(full.substring(0, base.length), base)) return null;
    return full.substring(base.length);
  }

  static String _withSlash(String dir) => dir.endsWith('/') ? dir : '$dir/';

  bool _same(String a, String b) => switch (this) {
    posix => a == b,
    windows => a.length == b.length && _asciiLower(a) == _asciiLower(b),
  };

  // Lower-cases A to Z only. NTFS folds case with its own table, which this
  // cannot read; A to Z is where it and any other table agree, and folding
  // them never changes a string's length, which [relative]'s substring
  // relies on.
  static String _asciiLower(String s) => String.fromCharCodes([
    for (final unit in s.codeUnits)
      if (unit >= 0x41 && unit <= 0x5A) unit + 0x20 else unit,
  ]);
}
