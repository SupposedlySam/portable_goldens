// Copy this file to your package's test/flutter_test_config.dart. Every test
// below test/ then compares its goldens against this machine's own baseline.
import 'dart:async';

import 'package:machine_goldens/machine_goldens.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  MachineGoldenComparator.install();
  await testMain();
}
