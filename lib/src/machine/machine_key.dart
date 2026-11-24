import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:portable_goldens/src/machine/flutter_sdk.dart';

/// What changes how this machine renders a golden.
///
/// Two Macs with the same engine, Dart, Flutter and `flutter_tester` binary
/// rendered the same widgets 1 to 20 pixels apart at the edges of anti-aliased
/// circles, and the only difference between them was the OS: macOS 26.6.2
/// (25G83) and 27.2.1 (26B131). So the OS's version and build are in the key,
/// next to what the Flutter side contributes: the engine, the framework and
/// Dart. The framework is there because text layout, painting and every
/// widget are framework code: a framework commit on the same engine, as on
/// Flutter's main channel, can move pixels.
///
/// The CPU model is not in it. The two Macs were an M4 Pro and an M4 Max, and
/// the OS version alone separated them; add a field here if two machines with
/// the same key are ever measured to render differently.
final class MachineKey {
  /// A key from its values, for tests and for reading a manifest back.
  const new({
    required this.os,
    required this.osVersion,
    required this.arch,
    required this.engineRevision,
    required this.frameworkRevision,
    required this.dartVersion,
  });

  /// The key of the process this runs in, with the SDK [sdk] (by default
  /// the one this process belongs to).
  ///
  /// A test process runs in `flutter_tester` and the `prepare` command in the
  /// `dart` of the same Flutter SDK; both report the same values (measured on
  /// macOS: `Abi` is `macos_arm64` in both, since `flutter_tester` is an arm64
  /// binary despite its `darwin-x64` folder).
  ///
  /// [engineRevision] and [frameworkRevision] are null when they cannot be
  /// found, and a caller must then not trust any baseline, since an update
  /// would go unnoticed: see [isComplete].
  factory current({Map<String, String>? environment, FlutterSdk? sdk}) {
    final flutter = sdk ?? FlutterSdk.current(environment: environment);
    return MachineKey(
      os: Platform.operatingSystem,
      // "Version 27.2.1 (Build 26B131)" on macOS, the build included.
      osVersion: Platform.operatingSystemVersion,
      arch: Abi.current().toString(),
      engineRevision: flutter?.engineRevision,
      frameworkRevision: flutter?.frameworkRevision,
      dartVersion: Platform.version.split(' ').first,
    );
  }

  /// A key from a manifest's JSON; throws [FormatException] when it is not
  /// one.
  factory fromJson(Map<String, Object?> json) {
    if (json case {
      'os': final String os,
      'osVersion': final String osVersion,
      'arch': final String arch,
      'dartVersion': final String dartVersion,
    }) {
      return MachineKey(
        os: os,
        osVersion: osVersion,
        arch: arch,
        engineRevision: json['engineRevision'] as String?,
        // A manifest written before the field existed: a key that differs,
        // so its folder is never this key's.
        frameworkRevision: json['frameworkRevision'] as String?,
        dartVersion: dartVersion,
      );
    }
    throw FormatException('Not a machine key', json);
  }

  /// `Platform.operatingSystem`: `macos`, `linux`, `windows`.
  final String os;

  /// `Platform.operatingSystemVersion`, which on macOS carries the build.
  final String osVersion;

  /// `Abi.current()` of the process, e.g. `macos_arm64`.
  final String arch;

  /// The Flutter engine commit whose artifacts the SDK runs tests with.
  final String? engineRevision;

  /// The Flutter framework commit the SDK is checked out at.
  final String? frameworkRevision;

  /// The Dart SDK version, e.g. `3.13.4`.
  final String dartVersion;

  /// Whether every value that can move pixels is known. Without the engine
  /// and the framework, an SDK update would reuse baselines it did not
  /// render.
  bool get isComplete => engineRevision != null && frameworkRevision != null;

  /// The readable values, as the manifest beside the baselines records them.
  Map<String, String?> toJson() => {
    'os': os,
    'osVersion': osVersion,
    'arch': arch,
    'engineRevision': engineRevision,
    'frameworkRevision': frameworkRevision,
    'dartVersion': dartVersion,
  };

  /// A short hash of every value: the name of this machine's folder.
  ///
  /// Any value that changes, an OS update say, names a different folder, so
  /// baselines rendered before it are never found, let alone reused.
  String get id {
    final hash = _fnv1a64(utf8.encode(_canonical));
    // An int is signed, so each 32-bit half is written on its own.
    String half(int value) =>
        (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return '${half(hash >> 32)}${half(hash)}';
  }

  String get _canonical => jsonEncode(toJson());

  @override
  // Every field is final and the class is final, so a key cannot change
  // under a map that holds it; @immutable would say so, but it lives in
  // package:meta, a dependency this package does not take for one marker.
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  bool operator ==(Object other) =>
      other is MachineKey && other._canonical == _canonical;

  @override
  // Immutable, as `==` above says.
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  int get hashCode => _canonical.hashCode;

  @override
  String toString() => toJson().entries
      .map((e) => '${e.key}: ${e.value ?? 'unknown'}')
      .join(', ');
}

// FNV-1a, 64-bit: a folder name needs a stable short hash, not a
// cryptographic one, and this keeps the package free of dependencies. The
// manifest beside the folder holds the readable values, and a manifest that
// disagrees with the key throws the folder away, so a collision cannot reuse
// a baseline either.
//
// The constants do not fit a JavaScript number; this package runs only on
// the Dart VM (it needs dart:io and dart:ffi), whose ints are 64-bit.
int _fnv1a64(List<int> bytes) {
  // The VM's 64-bit ints, as above.
  // ignore: avoid_js_rounded_ints
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}
