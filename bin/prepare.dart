// Before work: builds every missing baseline of this machine without running
// the suite, so the first test run compares at once instead of building.
//
//   dart run machine_goldens:prepare [--goldens <pathspec>]
//
// Run it from the package's root. Exits 1 when a build fails.
import 'dart:io';

import 'package:machine_goldens/baselines.dart';

import 'src/args.dart';

Future<void> main(List<String> args) async {
  final pathspec = goldensPathspec(args, usage: 'prepare');
  if (Platform.environment[childEnvironmentVariable] == '1') {
    stderr.writeln('prepare: refused inside a baseline build.');
    exit(1);
  }
  final goldens = MachineGoldens(packageDir: Directory.current.path);
  if (await goldens.fallbackReason case final reason?) {
    stdout.writeln('Machine baselines are not used here, because $reason; '
        'goldens compare with the committed images.');
    return;
  }
  stdout
    ..writeln('Machine ${goldens.key.id}: ${goldens.key}')
    ..writeln('Baselines in ${(await goldens.machineDir)!.path}');
  final all = await goldens.goldens(pathspec);
  final changed = await goldens.changedByBranch(pathspec);
  final missing = await goldens.missing(pathspec);
  var failed = 0;
  for (final MapEntry(key: commit, value: paths) in missing.entries) {
    stdout.writeln('Building ${commit.substring(0, 10)} '
        '(${paths.length} golden${paths.length == 1 ? '' : 's'})...');
    final started = DateTime.now();
    try {
      await goldens.build(commit);
      final seconds = DateTime.now().difference(started).inSeconds;
      stdout.writeln('  built in ${seconds}s');
    } on BuildFailure catch (failure) {
      failed++;
      stderr.writeln('  $failure');
    } on CheckoutUnavailable catch (unavailable) {
      stdout.writeln('  $unavailable; its goldens compare with the committed '
          'images');
    }
  }
  if (changed.isNotEmpty) {
    stdout.writeln('${changed.length} changed by this branch: each is its own '
        'baseline, and `report` lists it.');
  }
  stdout.writeln(failed == 0
      ? '${all.length} goldens: every baseline is in place.'
      : '$failed build${failed == 1 ? '' : 's'} failed.');
  if (failed > 0) exit(1);
}
