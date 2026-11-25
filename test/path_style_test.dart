import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/git/package_location.dart';
import 'package:portable_goldens/src/git/path_style.dart';

// Windows paths are tested on every OS: what this package does with them is
// string arithmetic, and CI does not run on Windows yet.
void main() {
  group('PathStyle.windows', () {
    const style = PathStyle.windows;

    test('joins segments with /, as git prints them', () {
      expect(style.portable(r'C:\repo\test\a.png'), 'C:/repo/test/a.png');
      expect(style.portable('C:/repo/test/a.png'), 'C:/repo/test/a.png');
    });

    test('knows a drive or a share is absolute, and nothing else is', () {
      expect(style.isAbsolute(r'C:\repo'), isTrue);
      expect(style.isAbsolute('d:/repo'), isTrue);
      expect(style.isAbsolute(r'\\server\share\repo'), isTrue);
      expect(style.isAbsolute('//server/share/repo'), isTrue);
      expect(style.isAbsolute(r'test\goldens\a.png'), isFalse);
      expect(style.isAbsolute('C:relative'), isFalse);
    });

    test('a path below a folder, whichever separators either uses', () {
      expect(
        style.relative('C:/repo/pkg/', r'C:\repo\pkg\test\goldens\a.png'),
        'test/goldens/a.png',
      );
      expect(
        style.relative(r'C:\repo\pkg', 'C:/repo/pkg/test/a_test.dart'),
        'test/a_test.dart',
      );
    });

    test('ignores the case of ASCII letters, as NTFS does', () {
      expect(style.relative('C:/Repo', r'c:\REPO\a.png'), 'a.png');
    });

    test('is empty for the folder itself, with or without a separator', () {
      expect(style.relative('C:/repo', r'C:\repo'), '');
      expect(style.relative('C:/repo/', r'C:\repo\'), '');
      expect(style.relative(r'C:\repo\', 'C:/repo'), '');
    });

    test('is null outside the folder, a sibling sharing its name included', () {
      expect(style.relative('C:/repo', 'C:/repository/a.png'), isNull);
      expect(style.relative('C:/repo', r'D:\repo\a.png'), isNull);
      expect(style.relative('C:/repo/pkg', 'C:/repo'), isNull);
    });

    test('calls a path outside when a non-ASCII letter differs in case, '
        'rather than guess', () {
      expect(style.relative('C:/Ärger', 'C:/ärger/a.png'), isNull);
      expect(style.relative('C:/Ärger', 'C:/Ärger/a.png'), 'a.png');
    });
  });

  group('PathStyle.posix', () {
    const style = PathStyle.posix;

    test(r'leaves \ alone: it is a letter in a file name', () {
      expect(style.portable(r'/repo/a\b.png'), r'/repo/a\b.png');
      expect(style.relative('/repo', r'/repo/a\b.png'), r'a\b.png');
    });

    test('is case-sensitive, and only / starts an absolute path', () {
      expect(style.relative('/repo', '/Repo/a.png'), isNull);
      expect(style.isAbsolute('/repo'), isTrue);
      expect(style.isAbsolute(r'C:\repo'), isFalse);
    });

    test('a path below the root, and the root itself', () {
      expect(style.relative('/', '/repo/a.png'), 'repo/a.png');
      expect(style.relative('/', '/'), '');
    });
  });

  group('PackageLocation on Windows', () {
    // As GitRepo.open builds it there: git prints the top level with /, the
    // package folder is what Directory.current says, with \.
    const location = PackageLocation(
      topLevel: 'C:/work/repo',
      prefix: 'packages/app/',
      packageDir: r'C:\work\repo\packages\app',
      style: PathStyle.windows,
    );

    test(r'a golden the file API names with \ is in the package', () {
      expect(
        location.repoPathOf(r'C:\work\repo\packages\app\test\goldens\a.png'),
        'packages/app/test/goldens/a.png',
      );
      expect(
        location.repoPathOf(r'test\goldens\a.png'),
        'packages/app/test/goldens/a.png',
      );
    });

    test('a path dependency elsewhere on the drive is outside the repository, '
        'and one inside is not', () {
      expect(location.contains(r'C:\work\design'), isFalse);
      expect(location.contains(r'C:\work\repo\packages\shared'), isTrue);
      expect(location.contains(r'c:\WORK\REPO'), isTrue);
      expect(location.repoPathOf('C:/work/repo'), isNull);
    });
  });
}
