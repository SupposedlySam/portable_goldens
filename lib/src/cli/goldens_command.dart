import 'package:portable_goldens/src/cli/cli_option.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/exit_code.dart';
import 'package:portable_goldens/src/cli/parsed_arguments.dart';

/// Which pngs are goldens, as a git pathspec glob relative to the package:
/// Flutter's convention of a `goldens` folder beside the test.
const defaultGoldens = '**/goldens/**/*.png';

/// The `--goldens` option every command takes.
const goldensOption = ValueOption(
  name: 'goldens',
  valueName: 'pathspec',
  help: 'which pngs are goldens, as a git pathspec relative to the package',
  defaultValue: defaultGoldens,
);

/// One `dart run portable_goldens:<name>` command.
///
/// A command reads its parsed options and writes to its context; it never
/// exits the process or reads `stdout` itself, so a test can run it in
/// process. Parsing, `--help` and the refusal inside a baseline build are
/// the runner's, once for every command.
abstract base class GoldensCommand {
  /// A command.
  const new();

  /// Its name: `prepare` in `dart run portable_goldens:prepare`.
  String get name;

  /// What it does and when to run it, for `--help`.
  String get summary;

  /// The options it takes.
  List<CliOption> get options;

  /// Runs it in [context] with [arguments].
  Future<ExitCode> run(CommandContext context, ParsedArguments arguments);

  /// Its usage, for `--help` and after a usage error.
  String get usage {
    final width = options.fold(
      0,
      (widest, option) =>
          option.synopsis.length > widest ? option.synopsis.length : widest,
    );
    final synopsis = options.map((o) => '[${o.synopsis}]').join(' ');
    return [
      'usage: dart run portable_goldens:$name $synopsis',
      '',
      summary,
      '',
      for (final option in options)
        '  ${option.synopsis.padRight(width)}  ${option.described}',
      '  ${'--help'.padRight(width)}  print this and exit',
    ].join('\n');
  }
}
