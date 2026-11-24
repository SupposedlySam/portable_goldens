// After work: lists the goldens that failed against this machine's baseline
// and the ones this branch changed, each with its diff image.
//
//   dart run portable_goldens:report [--goldens <pathspec>]
//
// Reads what the last test run recorded; run the tests first. Exits 1 when a
// golden failed.
import 'dart:io';

import 'package:portable_goldens/baselines.dart';

import 'src/args.dart';

Future<void> main(List<String> args) async {
  final pathspec = goldensPathspec(args, usage: 'report');
  final dir = Directory.current.path;
  final goldens = MachineGoldens(packageDir: dir);
  final entries = {for (final e in GoldenReport(dir).read()) e.golden: e};
  final repo = await GitRepo.open(dir);
  final prefix = repo?.packagePrefix ?? '';
  final changed = [
    for (final path in await goldens.changedByBranch(pathspec))
      path.substring(prefix.length),
  ];
  final failed = [
    for (final entry in entries.values)
      if (entry.outcome == GoldenOutcome.failed &&
          File('$dir/${entry.golden}').existsSync())
        entry,
  ];

  stdout.writeln(failed.isEmpty
      ? "No golden failed against this machine's baseline."
      : "Failed against this machine's baseline (${failed.length}):");
  for (final entry in failed) {
    stdout.writeln('  ${entry.golden}');
    for (final diff in entry.diffs) {
      stdout.writeln('    $diff');
    }
  }
  final base = await goldens.base;
  stdout.writeln(changed.isEmpty
      ? 'No golden changed by this branch.'
      : 'Changed by this branch since ${base?.substring(0, 10)} '
          '(${changed.length}):');
  for (final golden in changed) {
    stdout.writeln('  $golden');
    final entry = entries[golden];
    if (entry == null || entry.outcome != GoldenOutcome.changed) {
      stdout.writeln('    not compared yet: run its test for a diff');
    } else if (entry.diffs.isEmpty) {
      stdout.writeln('    no diff: ${entry.baseline}');
    } else {
      for (final diff in entry.diffs) {
        stdout.writeln('    $diff');
      }
    }
  }
  if (failed.isNotEmpty) exit(1);
}
