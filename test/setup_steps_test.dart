import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

void main() {
  SetupSteps parse(String yaml) =>
      SetupSteps.parse(yaml, source: '/work/app/pubspec.yaml');

  Matcher failsWith(String problem) => throwsA(
    isA<SetupConfigError>()
        .having((e) => e.source, 'source', '/work/app/pubspec.yaml')
        .having((e) => e.problem, 'problem', contains(problem)),
  );

  group('reads', () {
    test('the steps, in order, as written', () {
      final steps = parse('''
name: app
portable_goldens:
  setup:
    - dart run build_runner build --delete-conflicting-outputs
    - "echo 'quoted: kept' > out.txt"
''');

      expect(steps.commands, [
        'dart run build_runner build --delete-conflicting-outputs',
        "echo 'quoted: kept' > out.txt",
      ]);
    });

    test('a flow list, which a hand-written reader would misread', () {
      expect(
        parse('portable_goldens: {setup: [make gen, "a, b"]} # note').commands,
        ['make gen', 'a, b'],
      );
    });

    test('no steps when the pubspec does not configure any', () {
      for (final yaml in [
        'name: app',
        '',
        'name: app\nportable_goldens:\n',
        'portable_goldens:\n  setup:\n',
        'portable_goldens:\n  setup: []\n',
      ]) {
        expect(parse(yaml).isEmpty, isTrue, reason: yaml);
      }
    });

    test('no steps when the package has no pubspec', () {
      final dir = Directory.systemTemp.createTempSync('setup_steps');
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(SetupSteps.read(dir.path).isEmpty, isTrue);
    });

    test("the pubspec in the package's folder", () {
      final dir = Directory.systemTemp.createTempSync('setup_steps');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pubspec.yaml')
          .writeAsStringSync('portable_goldens:\n  setup:\n    - make gen\n');

      expect(SetupSteps.read(dir.path).commands, ['make gen']);
    });
  });

  group('refuses, naming the pubspec and the problem,', () {
    test('YAML that does not parse', () {
      expect(
        () => parse('portable_goldens:\n  setup: [unclosed\n'),
        failsWith('not valid YAML'),
      );
    });

    test('a pubspec whose top level is not a map', () {
      expect(() => parse('- a\n- b\n'), failsWith('top level is not a map'));
    });

    test('a configuration that is not a map', () {
      expect(
        () => parse('portable_goldens: make gen\n'),
        failsWith('`portable_goldens` is not a map'),
      );
    });

    test('a misspelled key, which would otherwise build without its step', () {
      expect(
        () => parse('portable_goldens:\n  setpu:\n    - make gen\n'),
        failsWith('has `setpu`; the only key it takes is `setup`'),
      );
    });

    test('steps that are not a list', () {
      expect(
        () => parse('portable_goldens:\n  setup: make gen\n'),
        failsWith('`portable_goldens.setup` is not a list'),
      );
    });

    test('a step that is not a command line', () {
      for (final (step, shown) in [
        ('42', '"42"'),
        ('""', '""'),
        ('"  "', '"  "'),
        ('[make, gen]', '"[make, gen]"'),
        ('{run: make}', '"{run: make}"'),
      ]) {
        expect(
          () => parse('portable_goldens:\n  setup:\n    - ok\n    - $step\n'),
          failsWith('item 2 is not a command line: $shown'),
          reason: step,
        );
      }
    });

    test('in a message that says where to look', () {
      expect(
        const SetupConfigError('/a/pubspec.yaml', 'it is wrong').toString(),
        'portable_goldens cannot read its configuration in /a/pubspec.yaml: '
        'it is wrong.',
      );
    });
  });

  group("names the package's baselines in the cache", () {
    test('as the package alone without steps, as before there were any', () {
      expect(SetupSteps.none.unitOf('packages__app'), 'packages__app');
    });

    test('apart from every other set of steps', () {
      const steps = SetupSteps(['make gen']);
      final unit = steps.unitOf('root');

      expect(unit, matches(RegExp(r'^root@[0-9a-f]{16}$')));
      expect(const SetupSteps(['make gen']).unitOf('root'), unit);
      for (final other in const [
        SetupSteps(['make gen --fast']),
        SetupSteps(['make gen', 'make gen']),
        SetupSteps(['make', 'gen']),
      ]) {
        expect(other.unitOf('root'), isNot(unit), reason: '${other.commands}');
      }
    });

    test('as a unit the store reads back', () {
      final unit = const SetupSteps(['make gen']).unitOf('root');

      expect(CommitBaselines.unitOf(unit, isDirectory: true), unit);
      expect(CommitBaselines.unitOf('$unit.lock', isDirectory: false), unit);
      expect(
        CommitBaselines.unitOf('.$unit.tmp-1-2-checkout', isDirectory: true),
        unit,
      );
    });
  });
}
