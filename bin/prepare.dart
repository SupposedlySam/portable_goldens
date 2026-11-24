// Before work: builds every missing baseline of this machine without running
// the suite, so the first test run compares at once instead of building.
//
//   dart run portable_goldens:prepare [--goldens <pathspec>]
//
// Run it from the package's root. Exits 1 when a build fails.
import 'dart:io';

import 'package:portable_goldens/baselines.dart';
import 'package:portable_goldens/src/cli/prepare.dart';

import 'src/args.dart';

Future<void> main(List<String> args) async {
  final pathspec = goldensPathspec(args, usage: 'prepare');
  if (Platform.environment[childEnvironmentVariable] == '1') {
    stderr.writeln('prepare: refused inside a baseline build.');
    exit(1);
  }
  final code = await prepare(
    MachineGoldens(packageDir: Directory.current.path),
    pathspec,
    out: stdout,
    err: stderr,
  );
  if (code != 0) exit(code);
}
