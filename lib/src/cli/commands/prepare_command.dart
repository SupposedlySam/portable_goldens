import 'package:portable_goldens/src/build/checkout_unavailable.dart';
import 'package:portable_goldens/src/cli/cli_option.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/exit_code.dart';
import 'package:portable_goldens/src/cli/goldens_command.dart';
import 'package:portable_goldens/src/cli/parsed_arguments.dart';
import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/session/machine_goldens.dart';
import 'package:portable_goldens/src/store/build_failure.dart';

/// The `prepare` command: before work, builds every missing baseline of this
/// machine without running the suite, so the first test run compares at
/// once.
///
/// Fails when a build failed, or when a build passed without writing a
/// golden it should have: "every baseline is in place" is said only after
/// asking the store again.
final class PrepareCommand extends GoldensCommand {
  /// The command.
  const new();

  @override
  String get name => 'prepare';

  @override
  String get summary =>
      'Before work: builds every missing baseline of this machine without\n'
      'running the suite, so the first test run compares at once.\n'
      "Run it from the package's root. Exits 1 when a build fails.";

  @override
  List<CliOption> get options => const [goldensOption];

  @override
  Future<ExitCode> run(
    CommandContext context,
    ParsedArguments arguments,
  ) async {
    final CommandContext(:goldens, :out, :err) = context;
    final pathspec = arguments.value(goldensOption);
    if (await goldens.fallbackReason case final reason?) {
      out.writeln(
        'Machine baselines are not used here, because $reason; '
        'goldens compare with the committed images.',
      );
      return ExitCode.success;
    }
    out.writeln('Machine ${goldens.key.id}: ${goldens.key}');
    if (await goldens.machineDir case final dir?) {
      out.writeln('Baselines in ${dir.path}');
    }
    final all = await goldens.goldens(pathspec);
    final changed = await goldens.changedByBranch(pathspec);
    final builds = await _buildMissing(goldens, pathspec, out, err);
    final unwritten = [
      for (final MapEntry(key: commit, value: paths) in (await goldens.missing(
        pathspec,
      )).entries)
        if (!builds.unbuilt.contains(commit))
          for (final path in paths) (commit, path),
    ];
    for (final (commit, path) in unwritten) {
      err.writeln(
        '  the build of ${shortSha(commit)} passed but did not '
        'write $path',
      );
    }
    if (changed.isNotEmpty) {
      out.writeln(
        '${changed.length} changed by this branch, and `report` lists '
        'each with its diff.',
      );
    }
    if (builds.failed == 0 && unwritten.isEmpty) {
      out.writeln('${all.length} goldens: every baseline is in place.');
      return ExitCode.success;
    }
    final summary = [
      if (builds.failed > 0) '${_count(builds.failed, 'build')} failed',
      if (unwritten.isNotEmpty)
        '${_count(unwritten.length, 'golden')} $_unwrittenByAPass',
    ].join('; ');
    out.writeln('$summary.');
    return ExitCode.failure;
  }

  // Builds each commit [goldens] is missing, and says how each went.
  Future<({int failed, Set<String> unbuilt})> _buildMissing(
    MachineGoldens goldens,
    String pathspec,
    StringSink out,
    StringSink err,
  ) async {
    final unbuilt = <String>{};
    var failed = 0;
    final missing = await goldens.missing(pathspec);
    for (final MapEntry(key: commit, value: paths) in missing.entries) {
      out.writeln(
        'Building ${shortSha(commit)} (${_count(paths.length, 'golden')})...',
      );
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
        out.writeln(
          '  $unavailable; its goldens compare with the committed images',
        );
      }
    }
    return (failed: failed, unbuilt: unbuilt);
  }
}

// "1 golden", "2 goldens".
String _count(int count, String noun) => '$count $noun${count == 1 ? '' : 's'}';

const _unwrittenByAPass = 'not written by a build that passed';
