import 'package:portable_goldens/src/cli/cli_option.dart';
import 'package:portable_goldens/src/cli/parsed_arguments.dart';

/// What a command line turned out to be.
sealed class ParseOutcome {
  const new();
}

/// A command line every option of which is known.
final class Parsed extends ParseOutcome {
  /// The command line, as [arguments].
  const new(this.arguments);

  /// Its values.
  final ParsedArguments arguments;
}

/// `--help` (or `-h`), wherever it is: nothing else is read.
final class HelpRequested extends ParseOutcome {
  /// `--help` was asked for.
  const new();
}

/// A command line that is not one the command takes.
final class UsageError extends ParseOutcome {
  /// What is wrong with it, in a sentence.
  const new(this.message);

  /// What is wrong, e.g. `--goldens needs a value`.
  final String message;
}

/// Reads a command line against the [options] a command takes.
///
/// Hand-rolled because `package:args` would be a dependency of every test
/// process that uses the comparator, for two commands with two options.
/// It takes `--name value`, `--name=value` and `--flag`, and nothing
/// positional; it never exits, it says what it found.
final class ArgumentParser {
  /// A parser for [options].
  const new(this.options);

  /// The options the command takes.
  final List<CliOption> options;

  /// The outcome of reading [args].
  ParseOutcome parse(List<String> args) {
    if (args.any((arg) => arg == '--help' || arg == '-h')) {
      return const HelpRequested();
    }
    final values = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) return UsageError('unexpected "$arg"');
      final equals = arg.indexOf('=');
      final name = arg.substring(2, equals < 0 ? null : equals);
      final inline = equals < 0 ? null : arg.substring(equals + 1);
      switch (_option(name)) {
        case null:
          return UsageError('unknown option --$name');
        case FlagOption() when inline != null:
          return UsageError('--$name takes no value');
        case FlagOption():
          flags.add(name);
        case ValueOption() when values.containsKey(name):
          return UsageError('--$name is given twice');
        case ValueOption() when inline != null:
          if (inline.isEmpty) return UsageError('--$name needs a value');
          values[name] = inline;
        case ValueOption() when i + 1 >= args.length:
          return UsageError('--$name needs a value');
        case ValueOption():
          values[name] = args[++i];
      }
    }
    return Parsed(ParsedArguments(values: values, flags: flags));
  }

  CliOption? _option(String name) {
    for (final option in options) {
      if (option.name == name) return option;
    }
    return null;
  }
}
