import 'dart:io';

import 'package:portable_goldens/src/build/checkout_unavailable.dart';
import 'package:portable_goldens/src/build/golden_test_files.dart';
import 'package:portable_goldens/src/build/png_snapshot.dart';
import 'package:portable_goldens/src/build/throwaway_checkout.dart';
import 'package:portable_goldens/src/git/git_repo.dart';
import 'package:portable_goldens/src/machine/flutter_sdk.dart';
import 'package:portable_goldens/src/process/process_runner.dart';
import 'package:portable_goldens/src/store/build_failure.dart';

/// Set in the environment of the `flutter test` that builds baselines.
///
/// A commit made after this package was adopted installs the comparator in
/// its own `flutter_test_config.dart`, so the child run would compare against
/// machine baselines, find its own missing, and start a build of its own: a
/// recursion with no floor. With this set, the comparator inside the child is
/// a plain `LocalFileComparator`, so `--update-goldens` writes the committed
/// paths of the throwaway checkout, and nothing in the child builds.
const childEnvironmentVariable = 'PORTABLE_GOLDENS_CHILD';

/// The default marker of a golden test file.
const defaultGoldenTestMarker = 'matchesGoldenFile';

/// Renders one commit's goldens on this machine.
final class BaselineBuilder {
  /// A builder for [repo]'s package, running the `flutter` of [sdk].
  new({
    required this.repo,
    required this.sdk,
    required this.environment,
    this.goldenTestMarker = defaultGoldenTestMarker,
    ProcessRunner runProcess = Process.run,
  }) : _run = runProcess;

  /// The repository the commits are in.
  final GitRepo repo;

  /// The SDK the child runs with: this process's own, so the child renders
  /// with the engine the key names.
  final FlutterSdk sdk;

  /// This process's environment, which the child inherits.
  final Map<String, String> environment;

  /// A test file at the commit is run when its source contains this.
  final String goldenTestMarker;

  final ProcessRunner _run;

  /// Whether this process is itself a child build.
  bool get isChild => environment[childEnvironmentVariable] == '1';

  /// Checks [commit] out in a throwaway `git worktree`, runs that commit's
  /// own golden tests there with `--update-goldens`, and copies every image
  /// the run wrote into [into], at its package-relative path. Returns those
  /// paths, with the command.
  ///
  /// The commit's own tests, not this checkout's: the committed png is what
  /// that commit's code drew on the machine that committed it, so the same
  /// code drawn here is what this machine should match. The tests run are
  /// the files [GoldenTestFiles] finds.
  ///
  /// The checkout goes beside [into], so a build killed before its cleanup
  /// leaves it where the next build's sweep finds it, and not in the system
  /// temp folder until a reboot.
  ///
  /// Throws [CheckoutUnavailable] when git cannot check the commit out, and
  /// [BuildFailure] when the commit's `pub get` or tests fail.
  Future<Built> build(String commit, Directory into) async {
    if (isChild) {
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
    return await ThrowawayCheckout.use(
      repo,
      commit,
      '${into.path}-checkout',
      (checkout) => _render(commit, checkout, into),
    );
  }

  Future<Built> _render(
    String commit,
    ThrowawayCheckout checkout,
    Directory into,
  ) async {
    final package = checkout.packageDir;
    final testArgs = [
      'test',
      '--update-goldens',
      ...GoldenTestFiles(package, marker: goldenTestMarker).arguments,
    ];
    final flutter = sdk.flutter;
    final shown =
        'git worktree add --detach <dir> $commit '
        '&& cd <dir>/${repo.location.prefix} '
        '&& $flutter pub get && $flutter ${testArgs.join(' ')}';
    final env = Map.of(environment)
      // The parent is a test process; the child is a tool run.
      ..remove('FLUTTER_TEST')
      ..[childEnvironmentVariable] = '1';

    Future<void> step(List<String> args, String what) async {
      final result = await _run(
        flutter,
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
          output: tailOf('${result.stdout}\n${result.stderr}'),
        );
      }
    }

    await step(['pub', 'get'], "in the commit's checkout");
    final before = PngSnapshot.of(package);
    await step(testArgs, 'with --update-goldens');
    // What the run wrote, and only that: a png that was in the checkout and
    // is untouched is the other machine's image, not a render of this one.
    final written = PngSnapshot.of(package).writtenSince(before);
    for (final path in written) {
      final copy = File('${into.path}/$path');
      copy.parent.createSync(recursive: true);
      File('$package$path').copySync(copy.path);
    }
    return Built(written, shown);
  }
}
