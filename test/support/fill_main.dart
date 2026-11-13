// One process filling a baseline: `test/store_test.dart` starts two at once.
//
//   dart fill_main.dart <cache root> <log file>
//
// The build appends this process's pid to the log, waits, and writes one
// image; the log's length is how many builds ran.
import 'dart:io';

import 'package:machine_goldens/baselines.dart';

import 'repo.dart';

Future<void> main(List<String> args) async {
  final store = BaselineStore.open(args[0], fakeKey());
  await store.fill('c0ffee', 'root', (into) async {
    File(args[1]).writeAsStringSync('$pid\n', mode: FileMode.append);
    await Future<void>.delayed(const Duration(seconds: 1));
    File('${into.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('rendered by $pid');
    return const Built(['test/goldens/a.png'], 'fake');
  });
  stdout.writeln(store.baseline('c0ffee', 'root', 'test/goldens/a.png')!
      .readAsStringSync());
}
