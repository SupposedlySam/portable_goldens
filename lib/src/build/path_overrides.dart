import 'dart:convert';
import 'dart:io';

import 'package:portable_goldens/src/git/package_location.dart';

/// The file pub reads overrides from, beside a `pubspec.yaml`.
const overridesFileName = 'pubspec_overrides.yaml';

/// The packages a commit's checkout could not reach by the relative paths in
/// its pubspecs, and the absolute folders this machine resolves them to.
///
/// A path dependency such as `path: ../design_system` names a folder
/// relative to the package. The throwaway checkout of a commit is somewhere
/// else, so a dependency that points out of the repository points at nothing
/// there, and the commit's `pub get` fails. A dependency inside the
/// repository needs nothing: the checkout has that commit's copy of it.
///
/// The developer's own resolution says where each package is: pub writes
/// `.dart_tool/package_config.json`, and a relative path dependency appears
/// in it as a relative `rootUri` (measured: `path: ../dep` is `../../dep`,
/// resolved against `.dart_tool/`), while hosted, git and absolute path
/// dependencies are absolute `file:` URIs, which a checkout reaches as well
/// as the developer does. So this reads JSON, and only writes YAML, which
/// needs no YAML package: the names are pub package names and the paths are
/// written as JSON strings, which YAML reads.
///
/// What the checkout gets is the dependency as it is on disk today, not as
/// it was at the commit: a commit is only rendered from its own code where
/// that code is in the repository.
final class PathOverrides {
  new _(this.root, this.packages, {this.unread});

  /// The overrides for [location]'s package, from the nearest
  /// `.dart_tool/package_config.json` at or above the package and at or
  /// below the repository's top level: a pub workspace keeps one, at its
  /// root, for all its packages.
  ///
  /// None when there is no such file, which leaves the checkout's `pub get`
  /// to fail loudly if it needs any; [unread] says why when there is a file
  /// and it cannot be read.
  factory of(PackageLocation location) {
    final root = _resolutionRoot(location);
    if (root == null) return PathOverrides._('', const {});
    final config = File('${location.topLevel}/$root.dart_tool/$_config');
    try {
      final packages = <String, String>{};
      for (final package in _packagesIn(config)) {
        final (name, rootUri) = package;
        // Absolute: hosted, git, or a path given absolutely, all of which
        // the checkout reaches as they are.
        if (Uri.parse(rootUri).hasScheme) continue;
        final dir = _withoutTrailingSlash(
          config.parent.uri.resolve(rootUri).toFilePath(),
        );
        if (!location.contains(dir)) packages[name] = dir;
      }
      return PathOverrides._(
        root,
        Map.fromEntries(
          packages.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
        ),
      );
    } on Object catch (error) {
      return PathOverrides._(
        root,
        const {},
        unread: '${config.path} could not be read: $error',
      );
    }
  }

  /// The folder of the resolution that holds the package, relative to the
  /// top level: empty at the top, else ending in `/`. The overrides are
  /// written there, since pub takes a workspace's overrides at its root.
  final String root;

  /// Each package outside the repository, by name, and its absolute folder,
  /// in name order.
  final Map<String, String> packages;

  /// Why the resolution could not be read, when there was one to read.
  final String? unread;

  /// The overrides file's text.
  String get yaml => [
    '# Written by portable_goldens: path dependencies outside the repository,',
    "# as this machine's own resolution has them.",
    'dependency_overrides:',
    for (final MapEntry(key: name, value: dir) in packages.entries) ...[
      '  $name:',
      '    path: ${jsonEncode(dir)}',
    ],
    '',
  ].join('\n');

  /// Writes the overrides into [checkout], the throwaway checkout's top
  /// level, and returns what was done, for the command a build shows; null
  /// when there is nothing to override.
  ///
  /// A commit that has its own overrides file at [root] keeps it, untouched:
  /// merging two would need a YAML reader, and the commit's own is what its
  /// author meant.
  String? writeInto(String checkout) {
    if (unread case final unread?) return '(no path overrides: $unread)';
    if (packages.isEmpty) return null;
    final shown = '<dir>/$root$overridesFileName';
    final file = File('$checkout/$root$overridesFileName');
    if (!file.parent.existsSync()) {
      return '(no path overrides: the commit has no <dir>/$root)';
    }
    if (file.existsSync()) {
      return "(kept the commit's own $shown, which may not reach "
          '${packages.keys.join(', ')})';
    }
    file.writeAsStringSync(yaml);
    return 'write $shown overriding ${packages.keys.join(', ')}';
  }
}

const _config = 'package_config.json';

// The nearest folder at or above the package, and at or below the top level,
// with a resolution; null when there is none.
String? _resolutionRoot(PackageLocation location) {
  var prefix = location.prefix;
  while (true) {
    if (File('${location.topLevel}/$prefix.dart_tool/$_config').existsSync()) {
      return prefix;
    }
    if (prefix.isEmpty) return null;
    final cut = prefix.lastIndexOf('/', prefix.length - 2);
    prefix = cut < 0 ? '' : prefix.substring(0, cut + 1);
  }
}

// Each package's name and rootUri; throws a FormatException on a file that
// does not have the shape pub writes.
Iterable<(String, String)> _packagesIn(File config) sync* {
  if (jsonDecode(config.readAsStringSync()) case {
    'packages': final List<Object?> packages,
  }) {
    for (final package in packages) {
      if (package case {
        'name': final String name,
        'rootUri': final String rootUri,
      }) {
        yield (name, rootUri);
      } else {
        throw FormatException('a package without a name and rootUri', package);
      }
    }
  } else {
    throw const FormatException('no packages list');
  }
}

String _withoutTrailingSlash(String path) =>
    path.length > 1 && (path.endsWith('/') || path.endsWith(r'\'))
    ? path.substring(0, path.length - 1)
    : path;
