import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/cli/argument_parser.dart';
import 'package:portable_goldens/src/cli/cli_option.dart';

void main() {
  const goldens = ValueOption(
    name: 'goldens',
    valueName: 'pathspec',
    help: 'which pngs',
    defaultValue: 'default/**',
  );
  const json = FlagOption(name: 'json', help: 'as json');
  const parser = ArgumentParser([goldens, json]);

  Parsed parsed(List<String> args) => parser.parse(args) as Parsed;

  String error(List<String> args) => switch (parser.parse(args)) {
    UsageError(:final message) => message,
    final other => fail('expected a usage error, got $other'),
  };

  test('nothing given: every default', () {
    final arguments = parsed(const []).arguments;
    expect(arguments.value(goldens), 'default/**');
    expect(arguments.flag(json), isFalse);
  });

  test('a value as the next argument or after =, and a flag', () {
    expect(parsed(['--goldens', 'a/**']).arguments.value(goldens), 'a/**');
    expect(parsed(['--goldens=a=b']).arguments.value(goldens), 'a=b');
    expect(parsed(['--json']).arguments.flag(json), isTrue);
    final both = parsed(['--json', '--goldens', 'x']).arguments;
    expect(both.flag(json), isTrue);
    expect(both.value(goldens), 'x');
  });

  test('--help or -h anywhere wins over everything else', () {
    expect(parser.parse(['--goldens', 'x', '--help']), isA<HelpRequested>());
    expect(parser.parse(['--nonsense', '-h']), isA<HelpRequested>());
  });

  test('each malformed command line says what is wrong', () {
    expect(error(['--nope']), 'unknown option --nope');
    expect(error(['stray']), 'unexpected "stray"');
    expect(error(['--goldens']), '--goldens needs a value');
    expect(error(['--goldens=']), '--goldens needs a value');
    expect(error(['--json=yes']), '--json takes no value');
    expect(
      error(['--goldens', 'a', '--goldens', 'b']),
      '--goldens is given twice',
    );
  });
}
