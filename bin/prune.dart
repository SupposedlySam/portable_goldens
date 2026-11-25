import 'dart:io';

import 'package:portable_goldens/src/cli/command_runner.dart';

/// `dart run portable_goldens:prune`; `--help` says what it does.
Future<void> main(List<String> args) async {
  exitCode = await runPortableGoldens('prune', args);
}
