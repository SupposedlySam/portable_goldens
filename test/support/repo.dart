import 'dart:io';

import 'package:machine_goldens/baselines.dart';

/// The key the tests' machine has; [osVersion] fakes an OS update.
MachineKey fakeKey({String osVersion = 'Version 27.2.1 (Build 26B131)'}) =>
    MachineKey(
      os: 'macos',
      osVersion: osVersion,
      arch: 'macos_arm64',
      engineRevision: 'af7e796e161ae0bb1ff0758c71a7105418bd9ded',
      frameworkRevision: '6a19cca56475dbfba1478ee68d7bd0c2ef891da1',
      dartVersion: '3.13.4',
    );

/// A git repository in a temporary folder, with a package at its root whose
/// `test/a_test.dart` draws `test/goldens/a.png` and `b.png`.
class TestRepo {
  TestRepo._(this.dir);

  /// A repository on `main` with one commit.
  static Future<TestRepo> create() async {
    final dir = Directory.systemTemp.createTempSync('machine_goldens_repo');
    final repo = TestRepo._(dir.resolveSymbolicLinksSync());
    await repo.git(['init', '--quiet', '--initial-branch=main']);
    await repo.git(['config', 'user.email', 'test@example.com']);
    await repo.git(['config', 'user.name', 'Test']);
    await repo.git(['config', 'commit.gpgsign', 'false']);
    repo
      ..write('pubspec.yaml', 'name: fixture\n')
      ..write('test/a_test.dart', '// draws with matchesGoldenFile\n')
      ..write('test/b_test.dart', '// draws nothing\n')
      ..write('test/goldens/a.png', 'committed a')
      ..write('test/goldens/b.png', 'committed b');
    await repo.commit('first');
    return repo;
  }

  /// The repository's folder, symbolic links resolved.
  final String dir;

  /// Writes [content] to [path] below [dir].
  void write(String path, String content) => File('$dir/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  /// Runs git in [dir] and returns its trimmed output; fails on an error.
  Future<String> git(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: dir);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')}: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  /// Commits everything and returns the commit.
  Future<String> commit(String message) async {
    await git(['add', '.']);
    await git(['commit', '--quiet', '-m', message]);
    return git(['rev-parse', 'HEAD']);
  }

  /// Deletes the repository.
  void delete() => Directory(dir).deleteSync(recursive: true);
}

/// Stands in for `flutter`: `pub get` passes, and `test --update-goldens`
/// "renders" each golden in [renders] into the checkout it runs in, writing
/// `rendered <golden> at <commit>`. git runs for real.
class FakeFlutter {
  /// Draws [renders] (package-relative), failing with [testExitCode].
  FakeFlutter({
    this.renders = const ['test/goldens/a.png', 'test/goldens/b.png'],
    this.testExitCode = 0,
    this.checkoutFails = false,
    this.draw,
  });

  /// The bytes a run at a commit writes for a golden; text naming both, by
  /// default.
  final List<int> Function(String golden, String commit)? draw;

  /// The goldens a test run writes.
  final List<String> renders;

  /// What a test run exits with.
  final int testExitCode;

  /// Whether `git worktree add` fails, as on a shallow clone.
  final bool checkoutFails;

  /// Every `flutter test` run: its arguments and environment.
  final testRuns = <({List<String> args, Map<String, String> env})>[];

  /// The [ProcessRunner] to hand to the code under test.
  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async {
    if (executable == 'git') {
      if (checkoutFails && arguments.contains('add')) {
        return ProcessResult(0, 128, '', 'fatal: invalid reference');
      }
      return Process.run(executable, arguments,
          workingDirectory: workingDirectory);
    }
    if (arguments.first == 'pub') return ProcessResult(0, 0, '', '');
    testRuns.add((args: arguments, env: environment ?? const {}));
    final head = await Process.run('git', ['rev-parse', 'HEAD'],
        workingDirectory: workingDirectory);
    final commit = (head.stdout as String).trim();
    for (final golden in renders) {
      final file = File('$workingDirectory/$golden')..createSync(recursive: true);
      if (draw case final draw?) {
        file.writeAsBytesSync(draw(golden, commit));
      } else {
        file.writeAsStringSync('rendered $golden at $commit');
      }
    }
    return ProcessResult(0, testExitCode, 'test output', 'Some tests failed.');
  }
}
