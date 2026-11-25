import 'package:portable_goldens/src/cli/byte_size.dart';
import 'package:portable_goldens/src/cli/cli_option.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/counted.dart';
import 'package:portable_goldens/src/cli/exit_code.dart';
import 'package:portable_goldens/src/cli/goldens_command.dart';
import 'package:portable_goldens/src/cli/parsed_arguments.dart';
import 'package:portable_goldens/src/git/commit_reachability.dart';
import 'package:portable_goldens/src/git/git_repo.dart';
import 'package:portable_goldens/src/prune/cache_inventory.dart';
import 'package:portable_goldens/src/prune/cache_pruner.dart';
import 'package:portable_goldens/src/prune/prune_policy.dart';
import 'package:portable_goldens/src/store/cache_root.dart';

/// The `prune` command: removes the baselines nobody needs any more, from
/// the cache every repository on the machine shares.
///
/// What goes is [PrunePolicy]'s to say; this reads the cache, asks the
/// repository it runs in about each commit, and says what it removed.
final class PruneCommand extends GoldensCommand {
  /// The command.
  const new();

  /// `--older-than <days>`: how long unused baselines are kept.
  static const olderThan = ValueOption(
    name: 'older-than',
    valueName: 'days',
    help: 'remove baselines unused for this many days, in any repository',
    defaultValue: '30',
    check: _wholeDays,
  );

  /// `--dry-run`: say what would go, and remove nothing.
  static const dryRun = FlagOption(
    name: 'dry-run',
    help: 'say what would be removed, and remove nothing',
  );

  @override
  String get name => 'prune';

  @override
  String get summary =>
      'Removes baselines nobody needs: ones unused for a while, in any\n'
      'repository, and ones of commits rebased or amended away here.\n'
      'Run it in a repository to judge its commits; a commit it does not\n'
      "have may be another repository's, and only age removes it.\n"
      'Exits 1 when something could not be removed.';

  @override
  List<CliOption> get options => const [olderThan, dryRun];

  @override
  Future<ExitCode> run(
    CommandContext context,
    ParsedArguments arguments,
  ) async {
    final CommandContext(:out, :err, :environment, :packageDir) = context;
    final root = defaultCacheRoot(environment: environment);
    final policy = PrunePolicy(
      unusedFor: Duration(days: int.parse(arguments.value(olderThan))),
      now: DateTime.now(),
    );
    final repo = await GitRepo.open(packageDir);
    final dry = arguments.flag(dryRun);
    out.writeln(
      '${dry ? 'Would prune' : 'Pruning'} $root, ${policy.described}.',
    );
    if (repo == null) {
      out.writeln(
        'Not in a git repository, so no commit is judged unreachable: only '
        'age removes baselines.',
      );
    }
    final result = await CachePruner(
      policy: policy,
      reachability: repo == null
          ? CommitReachability.none()
          : await CommitReachability.of(repo),
      dryRun: dry,
    ).prune(CacheInventory.scan(root));
    _write(result, out, err, dry: dry);
    return result.hasFailures ? ExitCode.failure : ExitCode.success;
  }

  void _write(
    PruneResult result,
    StringSink out,
    StringSink err, {
    required bool dry,
  }) {
    final width = result.actions.fold(
      0,
      (widest, a) => a.label.length > widest ? a.label.length : widest,
    );
    for (final action in result.actions) {
      final line =
          '  ${_verbs[action.outcome]} ${action.label.padRight(width)}  '
          '${byteSize(action.bytes).padLeft(8)}  ${action.reason}';
      if (action.error case final error?) {
        err.writeln('$line: $error');
      } else {
        out.writeln(line);
      }
    }
    final chosen = result.actions.where((a) => a.frees).length;
    out.writeln(
      chosen == 0
          ? 'Nothing to remove; kept ${counted(result.kept, 'baseline')}.'
          : '${dry ? 'Would free' : 'Freed'} ${byteSize(result.freed)} '
                '(${counted(chosen, 'folder')}); kept '
                '${counted(result.kept, 'baseline')}.',
    );
    if (result.keptAbsent > 0) {
      out.writeln(
        '${counted(result.keptAbsent, 'kept baseline')} of commits this '
        'repository does not have, which only age removes: another '
        'repository may use them.',
      );
    }
    if (result.keptUnknown > 0) {
      out.writeln(
        '${counted(result.keptUnknown, 'kept baseline')} of commits git '
        'could not judge here, which only age removes.',
      );
    }
  }

  static const Map<PruneOutcome, String> _verbs = {
    PruneOutcome.removed: 'removed      ',
    PruneOutcome.wouldRemove: 'would remove ',
    PruneOutcome.inUse: 'in use, kept ',
    PruneOutcome.failed: 'failed       ',
  };
}

String? _wholeDays(String value) => switch (int.tryParse(value)) {
  final days? when days >= 1 => null,
  _ => 'must be a whole number of days, 1 or more',
};
