import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/process/shell.dart';

void main() {
  group('posix', () {
    const shell = Shell.posix;

    test('runs a command line as sh would', () {
      expect(shell.executable, '/bin/sh');
      expect(shell.arguments('a && b'), ['-c', 'a && b']);
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

    test('runs a command line in cmd, without AutoRun', () {
      expect(shell.executable, 'cmd.exe');
      expect(shell.arguments('a && b'), ['/d', '/s', '/c', 'a && b']);
    });

    test('changes the PATH variable that is there, whatever its case', () {
      expect(shell.withFirstOnPath({'Path': r'C:\Windows'}, r'C:\sdk\bin'), {
        'Path': r'C:\sdk\bin;C:\Windows',
      });
    });
  });

  test("the shown command puts a folder first on the commands' PATH, as "
      'this OS runs it', () async {
    final shell = Shell.current;
    final folder = Platform.isWindows ? r'C:\sdk\bin' : '/sdk/bin';
    // cmd expands `%PATH%` when it reads the line, before `set` runs; `set
    // PATH` lists the variables starting PATH as they are when it runs.
    final printPath = Platform.isWindows ? 'set PATH' : r'echo "PATH=$PATH"';
    final result = await Process.run(
      shell.executable,
      shell.arguments('${shell.firstOnPathCommand(folder)} && $printPath'),
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

  test('a real step: quoting and && reach the shell intact', () async {
    const shell = Shell.posix;
    final result = await Process.run(
      shell.executable,
      shell.arguments("printf '%s' 'a b' && printf ' %s' \"\$X\""),
      environment: {'X': 'set'},
    );

    expect(result.stdout, 'a b set');
  }, skip: Platform.isWindows ? 'needs /bin/sh' : null);
}
