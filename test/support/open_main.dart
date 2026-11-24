// One process opening the store and filling one commit: `test/store_test.dart`
// starts several at once, all opening a store with no manifest yet.
//
//   dart open_main.dart <cache root> <commit> <start, ms since epoch>
//
// Each waits for the shared start time, so their opens land together.
import 'dart:io';

import 'package:portable_goldens/baselines.dart';

import 'repo.dart';

Future<void> main(List<String> args) async {
  final start = DateTime.fromMillisecondsSinceEpoch(int.parse(args[2]));
  final wait = start.difference(DateTime.now());
  if (!wait.isNegative) await Future<void>.delayed(wait);
  final store = BaselineStore.open(args[0], fakeKey());
  await store.fill(args[1], 'root', (into) async {
    File('${into.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsStringSync('rendered at ${args[1]}');
    return const Built(['test/goldens/a.png'], 'fake');
  });
}
