import 'dart:convert';
import 'dart:io';

/// A Flutter SDK on disk: the revisions that decide how it renders, and its
/// `flutter` executable.
final class FlutterSdk {
  /// The SDK whose folder is [root].
  const new(this.root);

  /// The SDK this process belongs to, or null when it cannot be found.
  ///
  /// `flutter test` puts `FLUTTER_ROOT` in the test process's environment
  /// (measured). A plain `dart run` may not, but its `dart` lives inside the
  /// SDK, at `<root>/bin/cache/dart-sdk/bin/dart`, as `flutter_tester` does at
  /// `<root>/bin/cache/artifacts/engine/<host>/flutter_tester`; so the SDK is
  /// the folder above the executable's `bin/cache`.
  static FlutterSdk? current({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    if (env['FLUTTER_ROOT'] case final root? when root.isNotEmpty) {
      return FlutterSdk(root);
    }
    final exe = Platform.resolvedExecutable;
    final at = exe.lastIndexOf(_join(['', 'bin', 'cache', '']));
    return at < 0 ? null : FlutterSdk(exe.substring(0, at));
  }

  /// The SDK's folder.
  final String root;

  /// Its `flutter` executable.
  String get flutter =>
      _join([root, 'bin', 'flutter${Platform.isWindows ? '.bat' : ''}']);

  /// Its `dart` executable.
  String get dart => _join([
    root,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    'dart${Platform.isWindows ? '.exe' : ''}',
  ]);

  /// The engine commit whose artifacts the SDK runs tests with, or null.
  ///
  /// `bin/cache/engine.stamp` first: the tool writes it when it downloads the
  /// engine artifacts, so it names the engine `flutter_tester` actually came
  /// from. `bin/internal/engine.version` is what the framework checkout asks
  /// for, which a checkout can change before the cache catches up; it is the
  /// fallback for an SDK whose cache has no stamp. Both held
  /// `af7e796e161ae0bb1ff0758c71a7105418bd9ded` on Flutter 3.47.5, as does
  /// `flutter --version --machine`, which costs a process launch per test
  /// file and so is not used.
  String? get engineRevision =>
      _read(['bin', 'cache', 'engine.stamp']) ??
      _read(['bin', 'internal', 'engine.version']);

  /// The framework commit the SDK is checked out at, or null.
  ///
  /// The commit its git checkout is at, read from `.git` without launching
  /// git, since this runs in every test process: `HEAD`, then the loose or
  /// packed ref it names. The fallback is `frameworkRevision` in
  /// `bin/cache/flutter.version.json`, which the tool writes. On Flutter
  /// 3.47.5 both held `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`, as did
  /// `git rev-parse HEAD`. Uncommitted edits to the framework are not seen.
  String? get frameworkRevision => _gitHead() ?? _versionFileRevision();

  String? _gitHead() {
    final head = _read(['.git', 'HEAD']);
    if (head == null || !head.startsWith('ref: ')) return head;
    final ref = head.substring('ref: '.length);
    if (_read(['.git', ...ref.split('/')]) case final loose?) return loose;
    for (final line in (_read(['.git', 'packed-refs']) ?? '').split('\n')) {
      if (line.endsWith(' $ref')) return line.split(' ').first;
    }
    return null;
  }

  String? _versionFileRevision() {
    final text = _read(['bin', 'cache', 'flutter.version.json']);
    if (text == null) return null;
    try {
      if (jsonDecode(text) case {'frameworkRevision': final String revision}) {
        return revision;
      }
    } on FormatException {
      // Half written: unknown.
    }
    return null;
  }

  // The trimmed text of the file at [segments] below [root]; null when it is
  // missing or empty.
  String? _read(List<String> segments) {
    final file = File(_join([root, ...segments]));
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }
}

String _join(List<String> segments) => segments.join(Platform.pathSeparator);
