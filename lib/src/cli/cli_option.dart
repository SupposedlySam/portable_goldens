/// One option a command takes on its command line.
sealed class CliOption {
  const new({required this.name, required this.help});

  /// Its name, without the `--`.
  final String name;

  /// What it does, in a phrase, for `--help`.
  final String help;

  /// How `--help` writes it.
  String get synopsis;

  /// What `--help` says of it.
  String get described => help;
}

/// An option with a value: `--name <value>` or `--name=<value>`.
final class ValueOption extends CliOption {
  /// The option `--`[name] `<`[valueName]`>`, [defaultValue] when absent.
  const new({
    required super.name,
    required super.help,
    required this.valueName,
    required this.defaultValue,
  });

  /// What `--help` calls its value.
  final String valueName;

  /// Its value when the command line does not give one.
  final String defaultValue;

  @override
  String get synopsis => '--$name <$valueName>';

  @override
  String get described => '$help (default: $defaultValue)';
}

/// An option without a value, false unless given: `--name`.
final class FlagOption extends CliOption {
  /// The flag `--`[name].
  const new({required super.name, required super.help});

  @override
  String get synopsis => '--$name';
}
