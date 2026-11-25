import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

import 'support/png.dart';
import 'support/repo.dart';

// A pointer as `git lfs` writes one, for an object of 1234 bytes.
final pointer =
    'version https://git-lfs.github.com/spec/v1\n'
    'oid sha256:${'4d7a2146' * 8}\n'
    'size 1234\n';

// Why the real Git LFS test cannot run here, or null when it can.
final String? noGitLfs = () {
  try {
    final result = Process.runSync('git', ['lfs', 'version']);
    return result.exitCode == 0
        ? null
        : 'git lfs is not installed (`git lfs version` exited '
              '${result.exitCode}), so the LFS round trip is not checked here';
  } on ProcessException catch (error) {
    return 'git could not be started: ${error.message}';
  }
}();

void main() {
  late TestRepo repo;
  late GitRepo git;
  late Directory outside;

  setUp(() async {
    repo = await TestRepo.create();
    git = (await GitRepo.open(repo.dir))!;
    outside = Directory.systemTemp.createTempSync('portable_goldens_lfs');
  });

  tearDown(() {
    repo.delete();
    outside.deleteSync(recursive: true);
  });

  // Commits a.png as an LFS pointer, tracked by an `lfs` filter in
  // `.gitattributes`, as `git lfs track` writes it.
  Future<String> commitPointer() async {
    repo
      ..write('.gitattributes', '*.png filter=lfs diff=lfs merge=lfs -text\n')
      ..write('test/goldens/a.png', pointer);
    return await repo.commit('a.png in LFS');
  }

  // A smudge filter standing in for `git lfs`: whatever the pointer, it
  // writes [image], as LFS writes the object a pointer names.
  Future<void> smudgeTo(List<int> image) async {
    final object = File('${outside.path}/object.png')..writeAsBytesSync(image);
    final script = File('${outside.path}/smudge.sh')
      ..writeAsStringSync('cat >/dev/null\ncat "${object.path}"\n');
    await repo.git(['config', 'filter.lfs.smudge', 'sh "${script.path}"']);
    // A required filter must clean too; the pointer is committed as it is.
    await repo.git(['config', 'filter.lfs.clean', 'cat']);
    await repo.git(['config', 'filter.lfs.required', 'true']);
  }

  group('show', () {
    test("is a commit's bytes, and null for a path it does not have", () async {
      final head = await repo.git(['rev-parse', 'HEAD']);

      final a = await git.show(head, 'test/goldens/a.png');

      expect(a, isA<CommittedBytes>());
      expect(utf8.decode((a! as CommittedBytes).bytes), 'committed a');
      expect(await git.show(head, 'test/goldens/none.png'), isNull);
    });

    test('is an LFS pointer, an unknown, where no filter turns it into the '
        'image', () async {
      final commit = await commitPointer();

      final a = await git.show(commit, 'test/goldens/a.png');

      expect(a, isA<LfsPointer>());
      final lfs = a! as LfsPointer;
      expect(lfs.size, 1234);
      expect(lfs.oid, startsWith('sha256:4d7a2146'));
      expect(lfs.why, contains('Git LFS pointer to 1234 bytes'));
      expect(lfs.why, contains('git lfs pull'));
    });

    test("is the image where the commit's filter smudges the pointer, as a "
        'checkout writes it', () async {
      final image = encodePng(2, 2, pixel: 0xff0000ff);
      await smudgeTo(image);
      final commit = await commitPointer();

      final a = await git.show(commit, 'test/goldens/a.png');

      expect(a, isA<CommittedBytes>());
      expect((a! as CommittedBytes).bytes, image);
      expect(
        await repo.git(['show', '$commit:test/goldens/a.png']),
        pointer.trim(),
        reason: 'what `git show` gives, and the code read before',
      );
    });

    test("takes the filters from the commit's own attributes, not the "
        "working tree's", () async {
      final image = encodePng(2, 2, pixel: 0xff00ff00);
      await smudgeTo(image);
      final tracked = await commitPointer();
      File('${repo.dir}/.gitattributes').deleteSync();
      final untracked = await repo.commit('LFS dropped, the pointer kept');
      // The working tree now has no attributes; the older commit had them.

      expect(
        await git.show(tracked, 'test/goldens/a.png'),
        isA<CommittedBytes>().having((b) => b.bytes, 'bytes', image),
      );
      expect(
        await git.show(untracked, 'test/goldens/a.png'),
        isA<LfsPointer>(),
        reason: 'a commit without the filter has the pointer as its bytes',
      );
    });

    test('is unread, not absent, when a required filter fails', () async {
      final commit = await commitPointer();
      await repo.git(['config', 'filter.lfs.smudge', 'false']);
      await repo.git(['config', 'filter.lfs.required', 'true']);

      final a = await git.show(commit, 'test/goldens/a.png');

      expect(a, isA<UnreadFile>());
      expect((a! as UnreadFile).why, contains('smudge filter lfs failed'));
    });

    test('with Git LFS, is the image LFS stores', () async {
      await repo.git(['lfs', 'install', '--local']);
      await repo.git(['lfs', 'track', '*.png']);
      final image = encodePng(2, 2, pixel: 0xffff0000);
      File('${repo.dir}/test/goldens/a.png').writeAsBytesSync(image);
      final commit = await repo.commit('a.png in LFS');

      expect(
        await git.show(commit, 'test/goldens/a.png'),
        isA<CommittedBytes>().having((b) => b.bytes, 'bytes', image),
      );
      expect(
        await repo.git(['show', '$commit:test/goldens/a.png']),
        startsWith('version https://git-lfs.github.com/spec/v1'),
        reason: 'the blob is a pointer: LFS is really in use',
      );
    }, skip: noGitLfs);
  });

  group('LfsPointer.parse', () {
    test('reads either URL the spec has had', () {
      expect(LfsPointer.parse(utf8.encode(pointer)), isNotNull);
      expect(
        LfsPointer.parse(
          utf8.encode('version https://hawser.github.com/spec/v1\n'),
        ),
        isA<LfsPointer>()
            .having((p) => p.oid, 'oid', isNull)
            .having((p) => p.size, 'size', isNull),
      );
    });

    test('is null for an image, other text, a large file, and bytes that '
        'are not UTF-8', () {
      expect(LfsPointer.parse(encodePng(2, 2, pixel: 0xff000000)), isNull);
      expect(LfsPointer.parse(utf8.encode('committed a')), isNull);
      expect(LfsPointer.parse(const []), isNull);
      expect(
        LfsPointer.parse(utf8.encode('$pointer${' ' * 1024}')),
        isNull,
        reason: 'a pointer is under 1024 bytes',
      );
      expect(LfsPointer.parse([...utf8.encode(pointer), 0xff]), isNull);
    });

    test('CommittedFile.of tells a pointer from bytes', () {
      expect(CommittedFile.of(utf8.encode(pointer)), isA<LfsPointer>());
      expect(
        CommittedFile.of(encodePng(2, 2, pixel: 0xff000000)),
        isA<CommittedBytes>(),
      );
    });
  });
}
