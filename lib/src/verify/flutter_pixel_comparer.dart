import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/build/baseline_builder.dart';
import 'package:portable_goldens/src/machine/flutter_sdk.dart';
import 'package:portable_goldens/src/process/process_runner.dart';
import 'package:portable_goldens/src/verify/pixel_comparer.dart';

/// The environment variable that tells the generated compare test where its
/// manifest is.
const verifyManifestVariable = 'PORTABLE_GOLDENS_VERIFY_MANIFEST';

/// Compares every pair in one generated `flutter test`, with the compare
/// `matchesGoldenFile` uses.
///
/// `GoldenFileComparator.compareLists` decodes the pngs with the engine, so
/// it needs a Flutter test binding, which a `dart run` command does not
/// have. A test file under the package's `.dart_tool/` runs with
/// `flutter test <file>`, and does not load the package's
/// `flutter_test_config.dart` (measured on Flutter 3.47.5), so the package's
/// own comparator setup never sees it. One run compares every pair, since
/// the run's start-up costs seconds.
final class FlutterPixelComparer implements PixelComparer {
  /// A compare in the package at [packageDir], with the `flutter` of [sdk].
  new({
    required this.packageDir,
    required this.sdk,
    required this.environment,
    ProcessRunner runProcess = Process.run,
  }) : _run = runProcess;

  /// The package whose `flutter_test` the compare runs with.
  final String packageDir;

  /// The SDK to run; null when none was found, and the compare then fails.
  final FlutterSdk? sdk;

  /// This process's environment, which the run inherits.
  final Map<String, String> environment;

  final ProcessRunner _run;

  /// The folder the generated test, its manifest and its results go in.
  String get workDir => '$packageDir/.dart_tool/portable_goldens/verify';

  @override
  Future<List<PixelVerdict>> compare(List<ImagePair> pairs) async {
    if (pairs.isEmpty) return const [];
    final flutter = sdk?.flutter;
    if (flutter == null) {
      throw const PixelCompareFailure(
        'no Flutter SDK found: FLUTTER_ROOT is not set, and this process '
        'does not run inside one',
      );
    }
    final dir = Directory(workDir)..createSync(recursive: true);
    final test = File('${dir.path}/compare_test.dart')
      ..writeAsStringSync(compareTestSource);
    final results = File('${dir.path}/results.json');
    if (results.existsSync()) results.deleteSync();
    final manifest = File('${dir.path}/manifest.json')
      ..writeAsStringSync(
        jsonEncode({
          'results': results.path,
          'pairs': [for (final pair in pairs) pair.toJson()],
        }),
      );
    final command = '$flutter test ${test.path}';
    final ProcessResult run;
    try {
      run = await _run(
        flutter,
        ['test', test.path],
        workingDirectory: packageDir,
        environment: Map.of(environment)
          ..remove('FLUTTER_TEST')
          // Nothing the run loads may build baselines, should it ever load
          // the package's comparator.
          ..[childEnvironmentVariable] = '1'
          ..[verifyManifestVariable] = manifest.path,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw PixelCompareFailure('`$command` could not start: ${e.message}');
    }
    final output = tailOf('${run.stdout}\n${run.stderr}');
    if (run.exitCode != 0 || !results.existsSync()) {
      throw PixelCompareFailure(
        '`$command` exited ${run.exitCode}'
        '${results.existsSync() ? '' : ' without writing its results'}',
        output: output,
      );
    }
    return _verdicts(results, pairs.length, command, output);
  }

  List<PixelVerdict> _verdicts(
    File results,
    int count,
    String command,
    String output,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(results.readAsStringSync());
    } on FormatException {
      throw PixelCompareFailure(
        '`$command` wrote results that are not json',
        output: output,
      );
    }
    if (decoded is! List || decoded.length != count) {
      throw PixelCompareFailure(
        '`$command` wrote results for a different number of pairs than '
        'the $count it was given',
        output: output,
      );
    }
    return [
      for (final verdict in decoded)
        switch (verdict) {
          {'same': true} => const PixelVerdict.same(),
          {
            'difference': final String difference,
            'diffs': final List<Object?> diffs,
          } =>
            PixelVerdict.different(difference, diffs.cast<String>()),
          _ => throw PixelCompareFailure(
            '`$command` wrote a result that is not a verdict: $verdict',
            output: output,
          ),
        },
    ];
  }
}

/// The generated test: reads the manifest [verifyManifestVariable] names,
/// compares each pair with `GoldenFileComparator.compareLists`, writes the
/// diff images of a pair that differs, and the verdicts as json.
///
/// Constant source, so no path is ever spliced into Dart code; every path
/// comes from the manifest.
const compareTestSource = r'''
// Generated by portable_goldens verify; rewritten on every run.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portable_goldens verify', () async {
    final manifestPath = Platform.environment['PORTABLE_GOLDENS_VERIFY_MANIFEST'];
    if (manifestPath == null) fail('PORTABLE_GOLDENS_VERIFY_MANIFEST is not set');
    final manifest =
        jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
    final verdicts = <Object>[];
    for (final pair in (manifest['pairs'] as List).cast<Map<String, dynamic>>()) {
      final result = await GoldenFileComparator.compareLists(
        File(pair['committed'] as String).readAsBytesSync(),
        File(pair['rendered'] as String).readAsBytesSync(),
      );
      if (result.passed) {
        verdicts.add({'same': true});
        result.dispose();
        continue;
      }
      final diffs = <String>[];
      for (final MapEntry(:key, :value) in (result.diffs ?? const {}).entries) {
        final bytes = await value.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) continue;
        final file = File('${pair['diffDir']}/$key.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes.buffer.asUint8List());
        diffs.add(file.path);
      }
      verdicts.add({
        'difference': result.error ?? 'the images differ',
        'diffs': diffs,
      });
      result.dispose();
    }
    File(manifest['results'] as String).writeAsStringSync(jsonEncode(verdicts));
  });
}
''';
