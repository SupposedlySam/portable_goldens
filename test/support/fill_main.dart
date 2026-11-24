// One process filling a baseline: `test/store_test.dart` starts two at once.
//
//   dart fill_main.dart <cache root> <log file> <release file>
//
// The build appends this process's pid to the log, then holds the lock until
// the release file exists, and writes one image; the log's length is how
// many builds ran. The test creates the release file only once the other
// process has said it is waiting, so the two have demonstrably contended.
import 'dart:io';

import 'package:portable_goldens/baselines.dart';

import 'repo.dart';

Future<void> main(List<String> args) async {
  final store = BaselineStore.open(args[0], fakeKey());
  await store.at('c0ffee', 'root').fill((into) async {
    File(args[1]).writeAsStringSync('$pid\n', mode: FileMode.append);
    while (!File(args[2]).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    File('${into.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('rendered by $pid');
    return const Built(['test/goldens/a.png'], 'fake');
  });
  stdout.writeln(
    store
        .at('c0ffee', 'root')
        .baseline('test/goldens/a.png')!
        .readAsStringSync(),
  );
}
