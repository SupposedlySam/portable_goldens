import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/portable_goldens.dart';
import 'package:portable_goldens/src/compare/notices.dart';

void main() {
  late GoldenFileComparator original;
  late StringBuffer said;
  late Notices processNotices;

  setUp(() {
    original = goldenFileComparator;
    processNotices = Notices.process;
    said = StringBuffer();
    Notices.process = Notices(said);
  });

  tearDown(() {
    goldenFileComparator = original;
    Notices.process = processNotices;
  });

  test('flutter test sets a LocalFileComparator, which install replaces', () {
    expect(goldenFileComparator.runtimeType, LocalFileComparator);

    PortableGoldenComparator.install();

    expect(goldenFileComparator, isA<PortableGoldenComparator>());
    expect('$said', isEmpty);
  });

  test('installing twice keeps the first, and says nothing', () {
    PortableGoldenComparator.install();
    final first = goldenFileComparator;

    PortableGoldenComparator.install();

    expect(goldenFileComparator, same(first));
    expect('$said', isEmpty);
  });

  for (final (name, make) in [
    ('another comparator', _Foreign.new),
    ('a LocalFileComparator subclass', _TolerantLocal.new),
  ]) {
    test('$name is left in place, and that is said once', () {
      final foreign = make();
      goldenFileComparator = foreign;

      PortableGoldenComparator.install();
      PortableGoldenComparator.install();

      expect(goldenFileComparator, same(foreign));
      expect(
        '$said',
        'portable_goldens: not installed: goldenFileComparator is a '
            '${foreign.runtimeType}, not the LocalFileComparator flutter '
            'test sets, so goldens compare with it and not with machine '
            'baselines.\n',
      );
    });

    test('$name with strict: install throws, and leaves it in place', () {
      final foreign = make();
      goldenFileComparator = foreign;

      expect(
        () => PortableGoldenComparator.install(strict: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('${foreign.runtimeType}'),
          ),
        ),
      );
      expect(goldenFileComparator, same(foreign));
      expect('$said', isEmpty);
    });
  }
}

final class _Foreign extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}

// A project's own tolerant comparator: replacing it would drop the
// project's choice without a word.
final class _TolerantLocal extends LocalFileComparator {
  new() : super(Uri.file('${Directory.current.path}/test/x.dart'));
}
