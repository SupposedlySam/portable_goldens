import 'dart:io';

import 'package:portable_goldens/src/machine/flutter_sdk.dart';
import 'package:portable_goldens/src/session/machine_goldens.dart';
import 'package:portable_goldens/src/verify/flutter_pixel_comparer.dart';
import 'package:portable_goldens/src/verify/pixel_comparer.dart';

/// Where a command runs and what it writes to: the seam that lets a test
/// drive a command in-process, with string sinks and a fake machine.
final class CommandContext {
  /// A command run in [packageDir], writing to [out] and [err].
  ///
  /// [goldens] opens the package's [MachineGoldens]; a test passes one with
  /// a fake key, cache and processes. [pixels] opens the pixel compare
  /// `verify` uses; a test passes a fake one.
  new({
    required this.packageDir,
    required this.out,
    required this.err,
    Map<String, String>? environment,
    MachineGoldens Function()? goldens,
    PixelComparer Function()? pixels,
  }) : environment = environment ?? Platform.environment,
       _openGoldens = goldens,
       _openPixels = pixels;

  /// The context of this process: its folder, its streams, its environment.
  factory process() => CommandContext(
    packageDir: Directory.current.path,
    out: stdout,
    err: stderr,
  );

  /// The package's root, which the command runs in.
  final String packageDir;

  /// Where results go.
  final StringSink out;

  /// Where problems go.
  final StringSink err;

  /// The environment the command runs in.
  final Map<String, String> environment;

  final MachineGoldens Function()? _openGoldens;

  /// The package's machine baselines, opened on first use.
  late final MachineGoldens goldens =
      _openGoldens?.call() ??
      MachineGoldens(packageDir: packageDir, environment: environment);

  final PixelComparer Function()? _openPixels;

  /// The pixel compare, opened on first use: by default a generated
  /// `flutter test` run with this environment's SDK.
  late final PixelComparer pixels =
      _openPixels?.call() ??
      FlutterPixelComparer(
        packageDir: packageDir,
        sdk: FlutterSdk.current(environment: environment),
        environment: environment,
      );
}
