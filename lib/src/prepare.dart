import 'builder.dart';
import 'session.dart';
import 'store.dart';

/// The `prepare` command: builds every missing baseline of [goldens] that
/// [pathspec] matches, telling [out] and [err], and returns the exit code.
///
/// 1 when a build failed, or when a build passed without writing a golden
/// it should have: "every baseline is in place" is said only after asking
/// the store again.
Future<int> prepare(
  MachineGoldens goldens,
  String pathspec, {
  required StringSink out,
  required StringSink err,
}) async {
  if (await goldens.fallbackReason case final reason?) {
    out.writeln('Machine baselines are not used here, because $reason; '
        'goldens compare with the committed images.');
    return 0;
  }
  out
    ..writeln('Machine ${goldens.key.id}: ${goldens.key}')
    ..writeln('Baselines in ${(await goldens.machineDir)!.path}');
  final all = await goldens.goldens(pathspec);
  final changed = await goldens.changedByBranch(pathspec);
  final missing = await goldens.missing(pathspec);
  final unbuilt = <String>{};
  var failed = 0;
  for (final MapEntry(key: commit, value: paths) in missing.entries) {
    out.writeln('Building ${commit.substring(0, 10)} '
        '(${paths.length} golden${paths.length == 1 ? '' : 's'})...');
    final started = DateTime.now();
    try {
      await goldens.build(commit);
      final seconds = DateTime.now().difference(started).inSeconds;
      out.writeln('  built in ${seconds}s');
    } on BuildFailure catch (failure) {
      failed++;
      unbuilt.add(commit);
      err.writeln('  $failure');
    } on CheckoutUnavailable catch (unavailable) {
      unbuilt.add(commit);
      out.writeln('  $unavailable; its goldens compare with the committed '
          'images');
    }
  }
  final unwritten = [
    for (final MapEntry(key: commit, value: paths)
        in (await goldens.missing(pathspec)).entries)
      if (!unbuilt.contains(commit))
        for (final path in paths) (commit, path),
  ];
  for (final (commit, path) in unwritten) {
    err.writeln('  the build of ${commit.substring(0, 10)} passed but did not '
        'write $path');
  }
  if (changed.isNotEmpty) {
    out.writeln('${changed.length} changed by this branch, and `report` lists '
        'each with its diff.');
  }
  final problems = failed + unwritten.length;
  if (problems == 0) {
    out.writeln('${all.length} goldens: every baseline is in place.');
    return 0;
  }
  final summary = [
    if (failed > 0) '$failed build${failed == 1 ? '' : 's'} failed',
    if (unwritten.isNotEmpty)
      '${unwritten.length} golden${unwritten.length == 1 ? '' : 's'} not '
          'written by a build that passed',
  ].join('; ');
  out.writeln('$summary.');
  return 1;
}
