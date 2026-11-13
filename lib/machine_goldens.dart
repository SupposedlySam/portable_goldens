/// A golden file comparator that compares each golden exactly against a
/// baseline this machine rendered, from the commit that last changed it.
///
/// ```dart
/// // test/flutter_test_config.dart
/// import 'dart:async';
///
/// import 'package:machine_goldens/machine_goldens.dart';
///
/// Future<void> testExecutable(FutureOr<void> Function() testMain) async {
///   MachineGoldenComparator.install();
///   await testMain();
/// }
/// ```
library;

export 'baselines.dart';
export 'src/comparator.dart' show MachineGoldenComparator;
