import 'dart:io';

/// Where a package sits in its git repository, and the conversions between
/// the three ways a path is written: absolute, relative to the repository's
/// top level (as git prints it), and relative to the package (as the tests
/// and the cache name a golden).
///
/// Every path this package hands git, or reads from it, goes through here, so
/// the arithmetic is written once.
final class PackageLocation {
  /// The package at [packageDir], [prefix] below [topLevel].
  const new({
    required this.topLevel,
    required this.prefix,
    required this.packageDir,
  });

  /// The working tree's top level.
  final String topLevel;

  /// The package's folder below [topLevel]: empty at the root, else ending in
  /// `/`, e.g. `packages/app/`.
  final String prefix;

  /// The package's folder, as it was given.
  final String packageDir;

  /// The package's name in the cache: its folder in the repository, `root`
  /// at the top. Two packages of one monorepo never share a commit's folder.
  String get unit => prefix.isEmpty
      ? 'root'
      : prefix.substring(0, prefix.length - 1).replaceAll('/', '__');

  /// [packagePathspec], a git pathspec glob relative to the package, as one
  /// relative to the top level.
  String pathspec(String packagePathspec) => ':(glob)$prefix$packagePathspec';

  /// The package-relative form of [repoPath], or null when it is outside the
  /// package.
  String? packagePath(String repoPath) =>
      repoPath.startsWith(prefix) ? repoPath.substring(prefix.length) : null;

  /// The repository-relative form of [path], which is absolute or relative to
  /// the package; null when it is outside the repository, or is its top
  /// level, which has no relative form.
  ///
  /// Symbolic links are resolved on both sides first: git prints
  /// `/private/tmp` where a test's path says `/tmp`.
  String? repoPathOf(String path) => switch (_fromTop(path)) {
    final relative? when relative.isNotEmpty => relative,
    _ => null,
  };

  /// Whether [path], absolute or relative to the package, is the top level
  /// or anything below it.
  bool contains(String path) => _fromTop(path) != null;

  // [path] relative to the top level, empty for the top level itself; null
  // when it is outside.
  String? _fromTop(String path) {
    final absolute = _isAbsolute(path) ? path : '$packageDir/$path';
    final real = _real(absolute);
    final realTop = _real(topLevel);
    if (real == realTop) return '';
    if (!real.startsWith('$realTop/')) return null;
    return real.substring(realTop.length + 1);
  }
}

bool _isAbsolute(String path) => path.startsWith('/') || path.contains(r':\');

// The path with symbolic links resolved, for a file that may not exist yet.
String _real(String path) {
  final file = File(path);
  if (file.existsSync()) return file.resolveSymbolicLinksSync();
  final dir = Directory(path);
  if (dir.existsSync()) return dir.resolveSymbolicLinksSync();
  final cut = path.lastIndexOf('/');
  if (cut <= 0) return path;
  return '${_real(path.substring(0, cut))}${path.substring(cut)}';
}
