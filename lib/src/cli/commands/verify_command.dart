import 'dart:convert';

import 'package:portable_goldens/src/cli/cli_option.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/counted.dart';
import 'package:portable_goldens/src/cli/exit_code.dart';
import 'package:portable_goldens/src/cli/goldens_command.dart';
import 'package:portable_goldens/src/cli/json_format.dart';
import 'package:portable_goldens/src/cli/parsed_arguments.dart';
import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/verify/golden_check.dart';
import 'package:portable_goldens/src/verify/golden_verifier.dart';

/// The `verify` command: before pushing, checks that each committed png is
/// what its own commit draws on this machine.
///
/// Only meaningful on the machine that rendered the pngs, so it says so
/// every time, rather than leave a mismatch elsewhere looking like a bug.
final class VerifyCommand extends GoldensCommand {
  /// The command.
  const new();

  /// `--all`: every tracked golden, not only the ones this branch changed.
  static const all = FlagOption(
    name: 'all',
    help: 'verify every tracked golden, not only those this branch changed',
  );

  /// `--json`: the checks as one json document, for tools.
  static const json = FlagOption(
    name: 'json',
    help: 'write the checks as json, for tools',
  );

  /// Where the images of each mismatch go, relative to the package.
  static const mismatchDir = '.dart_tool/portable_goldens/verify/mismatches';

  @override
  String get name => 'verify';

  @override
  String get summary =>
      'Before pushing: checks that each committed png is what its own\n'
      'commit draws on this machine, the one that rendered the pngs.\n'
      'Checks the goldens this branch changed, or every one with --all.\n'
      'Exits 1 when a png differs, or could not be checked.';

  @override
  List<CliOption> get options => const [goldensOption, all, json];

  @override
  Future<ExitCode> run(
    CommandContext context,
    ParsedArguments arguments,
  ) async {
    final CommandContext(:goldens, :out, :packageDir) = context;
    if (await goldens.fallbackReason case final reason?) {
      context.err.writeln(
        'Cannot verify: machine baselines are not used here, because '
        '$reason.',
      );
      return ExitCode.failure;
    }
    final everyGolden = arguments.flag(all);
    final checks = await GoldenVerifier(
      goldens: goldens,
      pixels: context.pixels,
      outputDir: '$packageDir/$mismatchDir',
    ).verify(arguments.value(goldensOption), all: everyGolden);
    final failed = checks.any((check) => check.isFailure);
    if (arguments.flag(json)) {
      out.writeln(
        jsonEncode(
          JsonFormat.verify.document({
            'machine': goldens.key.id,
            'passed': !failed,
            'checks': [for (final check in checks) check.toJson()],
          }),
        ),
      );
    } else {
      _write(checks, out, everyGolden: everyGolden, machine: goldens.key.id);
    }
    return failed ? ExitCode.failure : ExitCode.success;
  }

  void _write(
    List<GoldenCheck> checks,
    StringSink out, {
    required bool everyGolden,
    required String machine,
  }) {
    if (checks.isEmpty) {
      out.writeln(
        everyGolden
            ? 'No golden is tracked.'
            : 'No golden changed by this branch; `--all` verifies every '
                  'golden.',
      );
      return;
    }
    final which = everyGolden ? 'tracked' : 'changed by this branch';
    out.writeln(
      'Verifying ${counted(checks.length, 'golden')} $which, on machine '
      '$machine:',
    );
    for (final check in checks) {
      _writeCheck(check, out);
    }
    out
      ..writeln(_tally(checks))
      ..writeln(
        'A png only matches its render on the machine that rendered it; '
        'anywhere else, verify reports the machine as well as the commit.',
      );
  }

  void _writeCheck(GoldenCheck check, StringSink out) {
    switch (check) {
      case Verified(:final golden, :final commit):
        out.writeln('  verified      $golden (${shortSha(commit)})');
      case Mismatch(
        :final golden,
        :final commit,
        :final difference,
        :final committed,
        :final rendered,
        :final diffs,
      ):
        final sha = shortSha(commit);
        out
          ..writeln('  MISMATCH      $golden ($sha): $difference')
          ..writeln('    committed   $committed')
          ..writeln('    rendered    $rendered');
        for (final diff in diffs) {
          out.writeln('    diff        $diff');
        }
        out.writeln(
          '    $sha cannot draw its own png: was it committed before its '
          'code, or with part of it (git add -p, a split rebase)?',
        );
      case Unbuilt(:final golden, :final failure):
        out
          ..writeln('  UNBUILT       $golden')
          ..writeln('    $failure');
      case Unverifiable(:final golden, :final reason):
        out.writeln('  NOT CHECKED   $golden: $reason');
      case Uncommitted(:final golden):
        out.writeln('  uncommitted   $golden: no commit to check it against');
    }
  }

  // "2 verified, 1 mismatch, 1 uncommitted."
  String _tally(List<GoldenCheck> checks) {
    int count<T extends GoldenCheck>() => checks.whereType<T>().length;
    final parts = [
      (count<Verified>(), 'verified'),
      (count<Mismatch>(), count<Mismatch>() == 1 ? 'mismatch' : 'mismatches'),
      (count<Unbuilt>(), 'unbuilt'),
      (count<Unverifiable>(), 'not checked'),
      (count<Uncommitted>(), 'uncommitted'),
    ];
    return '${[for (final (n, label) in parts)
      if (n > 0) '$n $label'].join(', ')}.';
  }
}
