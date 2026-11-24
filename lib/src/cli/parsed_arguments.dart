import 'package:portable_goldens/src/cli/cli_option.dart';

/// A command line that parsed: every option's value, defaults filled in.
final class ParsedArguments {
  /// The option values `values`, by name, and the names of the flags given,
  /// `flags`.
  const new({required this._values, required this._flags});

  final Map<String, String> _values;
  final Set<String> _flags;

  /// The value of [option]: the one given, or its default.
  String value(ValueOption option) =>
      _values[option.name] ?? option.defaultValue;

  /// Whether [option] was given.
  bool flag(FlagOption option) => _flags.contains(option.name);
}
