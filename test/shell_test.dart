import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/process/process_runner.dart';
import 'package:portable_goldens/src/process/shell.dart';

void main() {
  group('posix', () {
    const shell = Shell.posix;

    test('runs a command line as sh would', () async {
      final runs = <List<String>>[];
      await shell.run(
        'a && b',
        runner: recorder(runs),
        workingDirectory: '/w',
        environment: {},
      );

      expect(runs, [
        ['/bin/sh', '-c', 'a && b'],
      ]);
    });

    test('puts a folder first on the PATH', () {
      expect(
        shell.withFirstOnPath({'PATH': '/usr/bin:/bin', 'HOME': '/h'}, '/sdk'),
        {'PATH': '/sdk:/usr/bin:/bin', 'HOME': '/h'},
      );
    });

    test('makes the folder the PATH when there is none', () {
      expect(shell.withFirstOnPath({}, '/sdk'), {'PATH': '/sdk'});
      expect(shell.withFirstOnPath({'PATH': ''}, '/sdk'), {'PATH': '/sdk'});
    });

    test('leaves the map it was given alone', () {
      final env = {'PATH': '/bin'};
      shell.withFirstOnPath(env, '/sdk');

      expect(env, {'PATH': '/bin'});
    });
  });

  group('windows', () {
    const shell = Shell.windows;

    test('runs a command line as the one line of a batch file, without '
        'AutoRun, and deletes the file after', () async {
      final runs = <List<String>>[];
      final scripts = <String>[];
      await shell.run(
        'set "X=a b" && echo %X%',
        runner: recorder(
          runs,
          onRun: (args) => scripts.add(File(args.last).readAsStringSync()),
        ),
        workingDirectory: '/w',
        environment: {},
      );

      expect(runs.single.take(3), ['cmd.exe', '/d', '/c']);
      expect(runs.single.last, endsWith('step.cmd'));
      expect(scripts, ['@echo off\r\nset "X=a b" && echo %X%\r\n']);
      expect(File(runs.single.last).parent.existsSync(), isFalse);
    });

    test('changes the PATH variable that is there, whatever its case', () {
      expect(shell.withFirstOnPath({'Path': r'C:\Windows'}, r'C:\sdk\bin'), {
        'Path': r'C:\sdk\bin;C:\Windows',
      });
    });
  });

  group('on this OS, for real', () {
    final shell = Shell.current;
    final cwd = Directory.current.path;

    Future<ProcessResult> run(String commandLine, {Map<String, String>? env}) =>
        shell.run(
          commandLine,
          runner: Process.run,
          workingDirectory: cwd,
          environment: env ?? Platform.environment,
        );

    test(
      "the shown command puts a folder first on the commands' PATH",
      () async {
        final folder = Platform.isWindows ? r'C:\sdk\bin' : '/sdk/bin';
        // cmd expands `%PATH%` when it reads the line, before `set` runs; `set
        // PATH` lists the variables starting PATH as they are when it runs.
        final printPath = Platform.isWindows
            ? 'set PATH'
            : r'echo "PATH=$PATH"';
        final result = await run(
          '${shell.firstOnPathCommand(folder)} && $printPath',
        );
        final expected = shell
            .withFirstOnPath(Platform.environment, folder)
            .entries
            .singleWhere((e) => e.key.toUpperCase() == 'PATH')
            .value;

        expect(result.exitCode, 0, reason: '${result.stderr}');
        final shown = const LineSplitter()
            .convert('${result.stdout}')
            .singleWhere((line) => line.toUpperCase().startsWith('PATH='));
        expect(shown.substring('PATH='.length), expected);
      },
    );

    test('double quotes, && and variables reach the shell intact', () async {
      final result = await run(
        Platform.isWindows
            ? 'echo "a b"&& echo %X%'
            : r'echo "a b" && echo "$X"',
        env: {...Platform.environment, 'X': 'set'},
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(const LineSplitter().convert('${result.stdout}'), [
        // cmd's echo prints its quotes, and the space before `&&`.
        if (Platform.isWindows) '"a b"' else 'a b',
        'set',
      ]);
    });

    test('a failing command fails the line, with its exit code, and what '
        'follows && does not run', () async {
      final result = await run(
        Platform.isWindows
            ? 'cmd /d /c exit 4 && echo ran'
            : 'sh -c "exit 4" && echo ran',
      );

      expect(result.exitCode, 4);
      expect('${result.stdout}', isNot(contains('ran')));
    });
  });

  test('the shown command for each shell', () {
    expect(Shell.posix.firstOnPathCommand('/sdk'), r'export PATH="/sdk:$PATH"');
    expect(
      Shell.windows.firstOnPathCommand(r'C:\sdk'),
      r'set "PATH=C:\sdk;%PATH%"',
    );
  });

  test('the shell of this OS', () {
    expect(Shell.current, Platform.isWindows ? Shell.windows : Shell.posix);
  });
}

/// A [ProcessRunner] that records each run, executable first, and succeeds;
/// [onRun] sees the arguments while the run is in progress.
ProcessRunner recorder(
  List<List<String>> runs, {
  void Function(List<String> arguments)? onRun,
}) =>
    (
      executable,
      arguments, {
      workingDirectory,
      environment,
      includeParentEnvironment = true,
      stdoutEncoding,
    }) async {
      runs.add([executable, ...arguments]);
      onRun?.call(arguments);
      return ProcessResult(0, 0, '', '');
    };
