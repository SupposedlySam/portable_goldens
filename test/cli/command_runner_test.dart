import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';
import 'package:portable_goldens/src/cli/command_context.dart';
import 'package:portable_goldens/src/cli/command_runner.dart';

void main() {
  // No command here gets as far as opening the package's goldens: each case
  // ends in the runner, and a goldens factory that fails proves it.
  Future<(int, String, String)> run(
    String name,
    List<String> args, {
    Map<String, String> environment = const {},
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runPortableGoldens(
      name,
      args,
      context: CommandContext(
        packageDir: '/nowhere',
        out: out,
        err: err,
        environment: environment,
        goldens: () => fail('the runner should not have run the command'),
      ),
    );
    return (code, '$out', '$err');
  }

  for (final command in commands) {
    group(command.name, () {
      test('--help prints its usage and every option, and exits 0', () async {
        final (code, out, err) = await run(command.name, ['--help']);

        expect(code, 0);
        expect(err, isEmpty);
        expect(
          out,
          startsWith('usage: dart run portable_goldens:${command.name} '),
        );
        for (final option in command.options) {
          expect(out, contains(option.synopsis));
        }
        expect(out, contains('--help'));
      });

      test(
        'an unknown option prints what is wrong and the usage, exit 64',
        () async {
          final (code, out, err) = await run(command.name, ['--bogus']);

          expect(code, 64);
          expect(out, isEmpty);
          expect(err, startsWith('${command.name}: unknown option --bogus.\n'));
          expect(err, contains(command.usage));
        },
      );

      test('inside a baseline build it is refused, exit 1', () async {
        final (code, out, err) = await run(
          command.name,
          const [],
          environment: {childEnvironmentVariable: '1'},
        );

        expect(code, 1);
        expect(out, isEmpty);
        expect(err, '${command.name}: refused inside a baseline build.\n');
      });
    });
  }

  test('the commands are the executables, one each', () {
    expect(commands.map((c) => c.name), ['prepare', 'report']);
  });

  test('an unknown command names the ones there are, exit 64', () async {
    final (code, _, err) = await run('verfiy', const []);

    expect(code, 64);
    expect(err, contains('no command "verfiy"'));
    expect(err, contains('prepare, report'));
  });
}
