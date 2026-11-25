import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/store/short_hash.dart';
import 'package:yaml/yaml.dart';

/// The key in `pubspec.yaml` that configures this package.
const configKey = 'portable_goldens';

/// The commands a baseline build runs in the commit's checkout after
/// `flutter pub get` and before its tests: what the checkout needs that git
/// does not hold, such as generated code (`build_runner`) that is ignored.
///
/// ```yaml
/// portable_goldens:
///   setup:
///     - dart run build_runner build --delete-conflicting-outputs
/// ```
///
/// They are read from the package as it is now, not from the commit: they
/// are today's knowledge of how to build an old commit, and the commit may
/// predate them. Copying the ignored files from the working tree instead was
/// rejected: it would render today's generated code into an old commit's
/// baseline.
final class SetupSteps {
  /// [commands], each one command line.
  const new(this.commands);

  /// The steps configured in the `pubspec.yaml` in [packageDir]; none when
  /// there is no pubspec, or it has no [configKey].
  ///
  /// Throws [SetupConfigError] when the configuration is there and is not
  /// one this reads: an unknown never passes, so a misspelled key fails the
  /// goldens rather than building without the step it meant.
  factory read(String packageDir) {
    final pubspec = File('$packageDir/pubspec.yaml');
    if (!pubspec.existsSync()) return none;
    return SetupSteps.parse(pubspec.readAsStringSync(), source: pubspec.path);
  }

  /// The steps in [yaml], the text of the pubspec at [source].
  ///
  /// Throws [SetupConfigError] as [SetupSteps.read] does.
  factory parse(String yaml, {required String source}) {
    Never fail(String problem) => throw SetupConfigError(source, problem);
    final Object? document;
    try {
      document = loadYaml(yaml, sourceUrl: Uri.file(source));
    } on YamlException catch (error) {
      fail('it is not valid YAML: ${error.message}');
    }
    final config = switch (document) {
      final YamlMap map => map[configKey],
      null => null,
      _ => fail('its top level is not a map'),
    };
    if (config == null) return none;
    if (config is! YamlMap) fail('`$configKey` is not a map');
    for (final key in config.keys) {
      if (key != _setupKey) {
        fail('`$configKey` has `$key`; the only key it takes is `$_setupKey`');
      }
    }
    final steps = switch (config[_setupKey]) {
      null => const <Object?>[],
      final YamlList list => list,
      _ => fail('`$configKey.$_setupKey` is not a list of command lines'),
    };
    return SetupSteps([
      for (final (index, step) in steps.indexed)
        if (step is String && step.trim().isNotEmpty)
          step
        else
          fail(
            '`$configKey.$_setupKey` item ${index + 1} is not a command line: '
            '${jsonEncode(step.toString())}',
          ),
    ]);
  }

  /// No steps: the build is `pub get`, then the tests.
  static const none = SetupSteps([]);

  static const _setupKey = 'setup';

  /// The command lines, in the order they run.
  final List<String> commands;

  /// Whether there are no steps.
  bool get isEmpty => commands.isEmpty;

  /// The cache's name for [packageUnit]'s baselines built with these steps:
  /// [packageUnit] itself when there are none, else with a hash of the steps.
  ///
  /// A baseline built with other steps (another code generator, other
  /// flags) may have rendered differently, so it is never read for these.
  /// Naming the folder after them, rather than checking a record inside it,
  /// keeps two branches that configure different steps from rebuilding each
  /// other's baselines on every switch. `prune` removes the old steps'
  /// folders once they go unused.
  String unitOf(String packageUnit) =>
      isEmpty ? packageUnit : '$packageUnit@${shortHash(jsonEncode(commands))}';
}

/// The `portable_goldens` configuration in a pubspec is not one this
/// package reads.
final class SetupConfigError implements Exception {
  /// [problem] with the configuration in the pubspec at [source].
  const new(this.source, this.problem);

  /// The pubspec's path.
  final String source;

  /// What is wrong, in a clause.
  final String problem;

  @override
  String toString() =>
      'portable_goldens cannot read its configuration in $source: $problem.';
}
