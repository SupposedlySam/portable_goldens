// Copy this file to your package's test/flutter_test_config.dart. Every test
// below test/ then compares its goldens against this machine's own baseline.
import 'dart:async';

import 'package:portable_goldens/portable_goldens.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PortableGoldenComparator.install();
  await testMain();
}
