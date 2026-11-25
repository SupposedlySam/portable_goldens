import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/cli/cli_option.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/exit_code.dart';
import 'package:portable_goldens/src/cli/goldens_command.dart';
import 'package:portable_goldens/src/cli/json_format.dart';
import 'package:portable_goldens/src/cli/parsed_arguments.dart';
import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/report/golden_report.dart';
import 'package:portable_goldens/src/report/work_summary.dart';

/// The `report` command: after work, the goldens that failed against this
/// machine's baseline and the ones this branch changed, each with its diff.
///
/// It reads what the last test run recorded, so it runs after the tests.
final class ReportCommand extends GoldensCommand {
  /// The command.
  const new();

  /// `--json`: the summary as one json document, for tools.
  static const json = FlagOption(
    name: 'json',
    help: 'write the summary as json, for tools',
  );

  @override
  String get name => 'report';

  @override
  String get summary =>
      "After work: lists the goldens that failed against this machine's\n"
      'baseline and the ones this branch changed, each with its diff.\n'
      'Reads what the last test run recorded; run the tests first.\n'
      'Exits 1 when a golden failed.';

  @override
  List<CliOption> get options => const [goldensOption, json];

  @override
  Future<ExitCode> run(
    CommandContext context,
    ParsedArguments arguments,
  ) async {
    final goldens = context.goldens;
    final dir = context.packageDir;
    final summary = WorkSummary.of(
      entries: GoldenReport(dir).read(),
      changedByBranch: await goldens.changedByBranch(
        arguments.value(goldensOption),
      ),
      base: await goldens.base,
      exists: (golden) => File('$dir/$golden').existsSync(),
    );
    if (arguments.flag(json)) {
      context.out.writeln(
        jsonEncode(JsonFormat.report.document(summary.toJson())),
      );
    } else {
      _write(summary, context.out);
    }
    return summary.failed.isEmpty ? ExitCode.success : ExitCode.failure;
  }

  void _write(WorkSummary summary, StringSink out) {
    final WorkSummary(:failed, :changed, :base) = summary;
    out.writeln(
      failed.isEmpty
          ? "No golden failed against this machine's baseline."
          : "Failed against this machine's baseline (${failed.length}):",
    );
    for (final entry in failed) {
      out.writeln('  ${entry.golden}');
      _writeDiffs(out, entry.diffs);
    }
    if (changed.isEmpty) {
      out.writeln('No golden changed by this branch.');
      return;
    }
    final since = base == null ? '' : ' since ${shortSha(base)}';
    out.writeln('Changed by this branch$since (${changed.length}):');
    for (final golden in changed) {
      out.writeln('  ${golden.golden}');
      switch (golden.entry) {
        case final entry? when golden.isCompared && entry.diffs.isEmpty:
          out.writeln('    no diff: ${entry.baseline}');
        case final entry? when golden.isCompared:
          _writeDiffs(out, entry.diffs);
        case _:
          out.writeln('    not compared yet: run its test for a diff');
      }
    }
  }

  void _writeDiffs(StringSink out, List<String> diffs) {
    for (final diff in diffs) {
      out.writeln('    $diff');
    }
  }
}
