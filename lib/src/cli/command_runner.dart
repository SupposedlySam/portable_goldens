import 'package:portable_goldens/src/build/baseline_builder.dart';
import 'package:portable_goldens/src/cli/argument_parser.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/commands/prepare_command.dart';
import 'package:portable_goldens/src/cli/commands/prune_command.dart';
import 'package:portable_goldens/src/cli/commands/report_command.dart';
import 'package:portable_goldens/src/cli/commands/verify_command.dart';
import 'package:portable_goldens/src/cli/exit_code.dart';
import 'package:portable_goldens/src/cli/goldens_command.dart';

/// Every command, each one executable in `bin/`.
const List<GoldensCommand> commands = [
  PrepareCommand(),
  PruneCommand(),
  ReportCommand(),
  VerifyCommand(),
];

/// Runs the command [name] with [args] in [context] (by default this
/// process's folder, streams and environment), and returns the exit code.
///
/// A command run inside a baseline build is refused: a commit's own tests
/// calling `prepare` would build baselines from within a build.
Future<int> runPortableGoldens(
  String name,
  List<String> args, {
  CommandContext? context,
}) async {
  final ctx = context ?? CommandContext.process();
  final command = commands.where((c) => c.name == name).firstOrNull;
  if (command == null) {
    ctx.err.writeln(
      'portable_goldens: no command "$name"; the commands are '
      '${commands.map((c) => c.name).join(', ')}.',
    );
    return ExitCode.usage.code;
  }
  switch (ArgumentParser(command.options).parse(args)) {
    case HelpRequested():
      ctx.out.writeln(command.usage);
      return ExitCode.success.code;
    case UsageError(:final message):
      ctx.err
        ..writeln('$name: $message.')
        ..writeln()
        ..writeln(command.usage);
      return ExitCode.usage.code;
    case Parsed(:final arguments):
      if (ctx.environment[childEnvironmentVariable] == '1') {
        ctx.err.writeln('$name: refused inside a baseline build.');
        return ExitCode.failure.code;
      }
      return (await command.run(ctx, arguments)).code;
  }
}
