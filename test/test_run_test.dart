import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/report/test_run.dart';

/// Answers each process launch with the next of [answers], and records it.
final class FakeRunner {
  new(this.answers);

  final List<ProcessResult Function()> answers;
  final launches = <List<String>>[];

  ProcessResult call(String executable, List<String> arguments) {
    launches.add([executable, ...arguments]);
    return answers.removeAt(0)();
  }
}

ProcessResult Function() prints(String stdout, {int exitCode = 0}) =>
    () => ProcessResult(0, exitCode, stdout, '');

ProcessResult Function() missing() =>
    () => throw const ProcessException('ps', [], 'not found');

void main() {
  group('ps (macOS and Linux)', () {
    test("the run is the parent's pid and its start time", () {
      final ps = FakeRunner([
        prints('  4242\n'),
        prints('Wed Nov 25 10:00:00 2026\n'),
      ]);

      expect(
        PsProcessTable(ps.call).runOf(17),
        '4242 Wed Nov 25 10:00:00 2026',
      );
      expect(ps.launches, [
        ['ps', '-o', 'ppid=', '-p', '17'],
        ['ps', '-o', 'lstart=', '-p', '4242'],
      ]);
    });

    test('nothing is a run when either answer is missing', () {
      expect(PsProcessTable(FakeRunner([prints('')]).call).runOf(17), isNull);
      expect(
        PsProcessTable(
          FakeRunner([prints('4242'), prints('', exitCode: 1)]).call,
        ).runOf(17),
        isNull,
      );
      expect(PsProcessTable(FakeRunner([missing()]).call).runOf(17), isNull);
    });
  });

  group('Win32_Process (Windows)', () {
    test("one PowerShell call, answered with the parent's pid and its "
        'creation time in UTC', () {
      final shell = FakeRunner([
        prints('4242 2026-11-25T10:00:00.1234567Z\r\n'),
      ]);

      expect(
        CimProcessTable(shell.call).runOf(17),
        '4242 2026-11-25T10:00:00.1234567Z',
      );
      expect(shell.launches.single.take(4), [
        'powershell.exe',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
      ]);
      expect(shell.launches.single.last, CimProcessTable.script(17));
    });

    test('the script asks about the child, then about its parent', () {
      final script = CimProcessTable.script(17);

      expect(script, contains('-Filter "ProcessId=17"'));
      expect(script, contains(r'"ProcessId=$($c.ParentProcessId)"'));
      expect(script, contains("ToUniversalTime().ToString('o')"));
    });

    test('nothing is a run when PowerShell is missing, fails, says nothing '
        'or says something else', () {
      String? answer(ProcessResult Function() result) =>
          CimProcessTable(FakeRunner([result]).call).runOf(17);

      expect(answer(missing()), isNull);
      expect(answer(prints('4242 2026-11-25T10:00:00Z', exitCode: 1)), isNull);
      expect(answer(prints('')), isNull);
      expect(answer(prints('Get-CimInstance : Access denied')), isNull);
      expect(answer(prints('4242')), isNull);
    });
  });

  test("this process's run, asked of the real OS, is its parent's pid and "
      'start time, the same each time', () {
    final run = currentRun();

    expect(run, matches(RegExp(r'^\d+ \S')));
    expect(currentRun(), run);
  });
}
