import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

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
class MachineKey {
  /// A key from its values, for tests and for reading a manifest back.
  const MachineKey({
    required this.os,
    required this.osVersion,
    required this.arch,
    required this.engineRevision,
    required this.frameworkRevision,
    required this.dartVersion,
  });

  /// The key of the process this runs in.
  ///
  /// A test process runs in `flutter_tester` and the `prepare` command in the
  /// `dart` of the same Flutter SDK; both report the same values (measured on
  /// macOS: `Abi` is `macos_arm64` in both, since `flutter_tester` is an arm64
  /// binary despite its `darwin-x64` folder).
  ///
  /// [engineRevision] and [frameworkRevision] are null when they cannot be
  /// found, and a caller must then not trust any baseline, since an update
  /// would go unnoticed.
  factory MachineKey.current({Map<String, String>? environment}) {
    final root = flutterRoot(environment: environment);
    return MachineKey(
      os: Platform.operatingSystem,
      // "Version 27.2.1 (Build 26B131)" on macOS, the build included.
      osVersion: Platform.operatingSystemVersion,
      arch: Abi.current().toString(),
      engineRevision: root == null ? null : engineRevisionOf(root),
      frameworkRevision: root == null ? null : frameworkRevisionOf(root),
      dartVersion: Platform.version.split(' ').first,
    );
  }

  /// A key from a manifest's JSON.
  factory MachineKey.fromJson(Map<String, Object?> json) => MachineKey(
    os: json['os'] as String,
    osVersion: json['osVersion'] as String,
    arch: json['arch'] as String,
    engineRevision: json['engineRevision'] as String?,
    // A manifest written before the field existed: a key that differs, so
    // its folder is never this key's.
    frameworkRevision: json['frameworkRevision'] as String?,
    dartVersion: json['dartVersion'] as String,
  );

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
    final hash = _fnv1a64(utf8.encode(jsonEncode(toJson())));
    // An int is signed, so each 32-bit half is written on its own.
    String half(int value) => (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return '${half(hash >> 32)}${half(hash)}';
  }

  @override
  bool operator ==(Object other) =>
      other is MachineKey && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => toJson().entries
      .map((e) => '${e.key}: ${e.value ?? 'unknown'}')
      .join(', ');

  /// The Flutter SDK this process belongs to.
  ///
  /// `flutter test` puts `FLUTTER_ROOT` in the test process's environment
  /// (measured). A plain `dart run` may not, but its `dart` lives inside the
  /// SDK, at `<root>/bin/cache/dart-sdk/bin/dart`, as `flutter_tester` does at
  /// `<root>/bin/cache/artifacts/engine/<host>/flutter_tester`; so the SDK is
  /// the folder above the executable's `bin/cache`.
  static String? flutterRoot({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final fromEnv = env['FLUTTER_ROOT'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    final exe = Platform.resolvedExecutable;
    final marker = '${Platform.pathSeparator}bin${Platform.pathSeparator}'
        'cache${Platform.pathSeparator}';
    final at = exe.lastIndexOf(marker);
    return at < 0 ? null : exe.substring(0, at);
  }

  /// The engine revision of the SDK at [root].
  ///
  /// `bin/cache/engine.stamp` first: the tool writes it when it downloads the
  /// engine artifacts, so it names the engine `flutter_tester` actually came
  /// from. `bin/internal/engine.version` is what the framework checkout asks
  /// for, which a checkout can change before the cache catches up; it is the
  /// fallback for an SDK whose cache has no stamp. Both held
  /// `af7e796e161ae0bb1ff0758c71a7105418bd9ded` on Flutter 3.47.5, as does
  /// `flutter --version --machine`, which costs a process launch per test
  /// file and so is not used.
  static String? engineRevisionOf(String root) {
    final sep = Platform.pathSeparator;
    for (final candidate in [
      '$root${sep}bin${sep}cache${sep}engine.stamp',
      '$root${sep}bin${sep}internal${sep}engine.version',
    ]) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      final value = file.readAsStringSync().trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// The framework revision of the SDK at [root].
  ///
  /// The commit its git checkout is at, read from `.git` without launching
  /// git, since this runs in every test process: `HEAD`, then the loose or
  /// packed ref it names. The fallback is `frameworkRevision` in
  /// `bin/cache/flutter.version.json`, which the tool writes. On Flutter
  /// 3.47.5 both held `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`, as did
  /// `git rev-parse HEAD`. Uncommitted edits to the framework are not seen.
  static String? frameworkRevisionOf(String root) {
    final sep = Platform.pathSeparator;
    String? read(String path) {
      final file = File(path);
      if (!file.existsSync()) return null;
      final value = file.readAsStringSync().trim();
      return value.isEmpty ? null : value;
    }

    final git = '$root$sep.git';
    if (read('$git${sep}HEAD') case final head?) {
      if (!head.startsWith('ref: ')) return head;
      final ref = head.substring('ref: '.length);
      if (read('$git$sep${ref.replaceAll('/', sep)}') case final loose?) {
        return loose;
      }
      for (final line in (read('$git${sep}packed-refs') ?? '').split('\n')) {
        if (line.endsWith(' $ref')) return line.split(' ').first;
      }
    }
    final version = read('$root${sep}bin${sep}cache${sep}flutter.version.json');
    if (version == null) return null;
    try {
      final json = jsonDecode(version);
      if (json is Map && json['frameworkRevision'] is String) {
        return json['frameworkRevision'] as String;
      }
    } on FormatException {
      // Half written: unknown.
    }
    return null;
  }
}

// FNV-1a, 64-bit: a folder name needs a stable short hash, not a
// cryptographic one, and this keeps the package free of dependencies. The
// manifest beside the folder holds the readable values, and a manifest that
// disagrees with the key throws the folder away, so a collision cannot reuse
// a baseline either.
int _fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}
