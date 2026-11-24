import 'dart:io';

/// The test files of a package that make goldens, found by a marker in their
/// source.
final class GoldenTestFiles {
  /// Finds the files that contain [marker] in [packageDir], which ends in
  /// `/`.
  const new(this.packageDir, {required this.marker});

  /// The package's folder, ending in `/`.
  final String packageDir;

  /// A test file is run when its source contains this.
  final String marker;

  /// The package-relative paths to hand `flutter test`: the files under
  /// `test/` whose source contains [marker], or all of `test/` when none
  /// does, which is slower but finds goldens made some other way. Empty when
  /// the package has no `test/`.
  List<String> get arguments {
    final tests = Directory('${packageDir}test');
    if (!tests.existsSync()) return const [];
    final found = <String>[
      for (final entity in tests.listSync(recursive: true, followLinks: false))
        if (entity is File &&
            entity.path.endsWith('_test.dart') &&
            entity.readAsStringSync().contains(marker))
          entity.path.substring(packageDir.length),
    ];
    return found.isEmpty ? const ['test'] : (found..sort());
  }
}
