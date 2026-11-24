import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

void main() {
  late Directory package;

  setUp(
    () => package = Directory.systemTemp.createTempSync(
      'portable_goldens_report',
    ),
  );
  tearDown(() => package.deleteSync(recursive: true));

  ReportEntry failed(String golden) => ReportEntry(
    golden: golden,
    outcome: GoldenOutcome.failed,
    baseline: "this machine's baseline",
    diffs: const [],
    at: DateTime.now(),
  );

  test("a run's first write sweeps what an earlier run left; what this run "
      'wrote stays', () {
    GoldenReport(
      package.path,
      run: () => 'earlier',
    ).record(failed('test/goldens/fixed_since.png'));

    // The next run: one process records, another only passes.
    GoldenReport(
      package.path,
      run: () => 'next',
    ).record(failed('test/goldens/a.png'));
    GoldenReport(package.path, run: () => 'next').clear('test/goldens/b.png');

    expect(
      [for (final entry in GoldenReport(package.path).read()) entry.golden],
      ['test/goldens/a.png'],
    );
  });

  test('a run that only passes still sweeps the last run', () {
    GoldenReport(
      package.path,
      run: () => 'earlier',
    ).record(failed('test/goldens/a.png'));

    GoldenReport(package.path, run: () => 'next').clear('test/goldens/b.png');

    expect(GoldenReport(package.path).read(), isEmpty);
  });

  test("where the run cannot be told, nothing is swept", () {
    GoldenReport(
      package.path,
      run: () => 'earlier',
    ).record(failed('test/goldens/a.png'));

    GoldenReport(package.path, run: () => null).clear('test/goldens/b.png');

    expect(GoldenReport(package.path).read(), hasLength(1));
  });

  test("this process's run is its parent's pid and start time", () {
    final run = currentRun();

    expect(run, matches(RegExp(r'^\d+ \S')));
    expect(currentRun(), run);
  }, skip: Platform.isWindows ? 'no ps on Windows' : false);
}
