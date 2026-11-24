import 'dart:io';

import 'git.dart';
import 'store.dart';

/// Set in the environment of the `flutter test` that builds baselines.
///
/// A commit made after this package was adopted installs the comparator in
/// its own `flutter_test_config.dart`, so the child run would compare against
/// machine baselines, find its own missing, and start a build of its own: a
/// recursion with no floor. With this set, the comparator inside the child is
/// a plain `LocalFileComparator`, so `--update-goldens` writes the committed
/// paths of the throwaway checkout, and nothing in the child builds.
const childEnvironmentVariable = 'PORTABLE_GOLDENS_CHILD';

/// `Process.run`, or a stand-in for it in tests.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment,
});

/// A commit could not be checked out (a shallow clone, say). The comparator
/// then compares with the committed image instead.
class CheckoutUnavailable implements Exception {
  /// [commit] could not be checked out, and git said [reason].
  const CheckoutUnavailable(this.commit, this.reason);

  /// The commit.
  final String commit;

  /// What git printed.
  final String reason;

  @override
  String toString() => 'commit $commit could not be checked out: $reason';
}

/// Renders one commit's goldens on this machine.
class BaselineBuilder {
  /// A builder for [repo]'s package, running the `flutter` of [flutterRoot].
  BaselineBuilder({
    required this.repo,
    required this.flutterRoot,
    required this.environment,
    this.goldenTestMarker = 'matchesGoldenFile',
    ProcessRunner? runProcess,
  }) : _run = runProcess ?? Process.run;

  /// The repository the commits are in.
  final GitRepo repo;

  /// The SDK the child runs with: this process's own, so the child renders
  /// with the engine the key names.
  final String flutterRoot;

  /// This process's environment, which the child inherits.
  final Map<String, String> environment;

  /// A test file at the commit is run when its source contains this.
  final String goldenTestMarker;

  final ProcessRunner _run;

  String get _flutter =>
      '$flutterRoot/bin/flutter${Platform.isWindows ? '.bat' : ''}';

  /// Checks [commit] out in a throwaway `git worktree`, runs that commit's
  /// own golden tests there with `--update-goldens`, and copies every image
  /// the run wrote into [into], at its package-relative path. Returns those
  /// paths, with the command.
  ///
  /// The commit's own tests, not this checkout's: the committed png is what
  /// that commit's code drew on the machine that committed it, so the same
  /// code drawn here is what this machine should match. The tests run are
  /// the files under `test/` whose source contains [goldenTestMarker], or all
  /// of `test/` when none does, which is slower but finds goldens made some
  /// other way.
  ///
  /// Throws [CheckoutUnavailable] when git cannot check the commit out, and
  /// [BuildFailure] when the commit's `pub get` or tests fail.
  Future<Built> build(String commit, Directory into) async {
    if (environment[childEnvironmentVariable] == '1') {
      // The comparator does not get here in a child run; this is the second
      // wall, for a caller that forgot.
      throw BuildFailure(
        commit: commit,
        command: '(none)',
        message:
            'refused: this process is itself building baselines '
            '($childEnvironmentVariable=1)',
      );
    }
    // Beside [into], so a build killed before its cleanup leaves the
    // checkout where the next build's sweep finds it, and not in the system
    // temp folder until a reboot. Its registration in the repository is what
    // the prune before `add` drops.
    final checkout = '${into.path}-checkout';
    await _run('git', ['worktree', 'prune'], workingDirectory: repo.topLevel);
    try {
      final added = await _run('git', [
        // A checkout for rendering must not run the repo's hooks.
        if (!Platform.isWindows) ...['-c', 'core.hooksPath=/dev/null'],
        'worktree', 'add', '--detach', checkout, commit,
      ], workingDirectory: repo.topLevel);
      if (added.exitCode != 0) {
        throw CheckoutUnavailable(commit, '${added.stderr}'.trim());
      }
      final package = '$checkout/${repo.packagePrefix}';
      final files = _goldenTests(package);
      final testArgs = ['test', '--update-goldens', ...files];
      final shown =
          'git worktree add --detach <dir> $commit && cd <dir>/${repo.packagePrefix} '
          '&& $_flutter pub get && $_flutter ${testArgs.join(' ')}';
      final env = Map.of(environment)
        // The parent is a test process; the child is a tool run.
        ..remove('FLUTTER_TEST')
        ..[childEnvironmentVariable] = '1';

      Future<void> step(List<String> args, String what) async {
        final result = await _run(
          _flutter,
          args,
          workingDirectory: package,
          environment: env,
          includeParentEnvironment: false,
        );
        if (result.exitCode != 0) {
          throw BuildFailure(
            commit: commit,
            command: shown,
            message: '`flutter ${args.first}` $what exited ${result.exitCode}',
            output: _tail('${result.stdout}\n${result.stderr}'),
          );
        }
      }

      await step(['pub', 'get'], 'in the commit\'s checkout');
      final before = _pngTimes(package);
      await step(testArgs, 'with --update-goldens');
      // What the run wrote, and only that: a png that was in the checkout and
      // is untouched is the other machine's image, not a render of this one.
      final written = <String>[];
      _pngTimes(package).forEach((path, time) {
        if (before[path] == time) return;
        final copy = File('${into.path}/$path');
        copy.parent.createSync(recursive: true);
        File('$package$path').copySync(copy.path);
        written.add(path);
      });
      return Built(written..sort(), shown);
    } finally {
      await _run('git', [
        'worktree',
        'remove',
        '--force',
        checkout,
      ], workingDirectory: repo.topLevel);
      final left = Directory(checkout);
      if (left.existsSync()) left.deleteSync(recursive: true);
      await _run('git', ['worktree', 'prune'], workingDirectory: repo.topLevel);
    }
  }

  List<String> _goldenTests(String package) {
    final tests = Directory('${package}test');
    if (!tests.existsSync()) return const [];
    final found = <String>[
      for (final entity in tests.listSync(recursive: true, followLinks: false))
        if (entity is File &&
            entity.path.endsWith('_test.dart') &&
            entity.readAsStringSync().contains(goldenTestMarker))
          entity.path.substring(package.length),
    ];
    return found.isEmpty ? const ['test'] : (found..sort());
  }
}

// Every png in the package, by package-relative path, with its modification
// time; tool output and failure images are skipped.
Map<String, DateTime> _pngTimes(String package) {
  final times = <String, DateTime>{};
  final root = Directory(package);
  if (!root.existsSync()) return times;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.png')) continue;
    final path = entity.path.substring(package.length);
    final segments = path.split('/');
    if (segments.contains('.dart_tool') ||
        segments.contains('build') ||
        segments.contains('failures')) {
      continue;
    }
    times[path] = entity.lastModifiedSync();
  }
  return times;
}

String _tail(String text, {int lines = 40}) {
  final all = text.trim().split('\n');
  return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
}
