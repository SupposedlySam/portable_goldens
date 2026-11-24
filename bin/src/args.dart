import 'dart:io';

/// Which pngs are goldens, as a git pathspec glob relative to the package:
/// Flutter's convention of a `goldens` folder beside the test.
const defaultGoldens = '**/goldens/**/*.png';

/// The `--goldens` value of [args], or [defaultGoldens]; exits on anything
/// else.
String goldensPathspec(List<String> args, {required String usage}) {
  if (args.isEmpty) return defaultGoldens;
  if (args.length == 2 && args.first == '--goldens') return args.last;
  stderr.writeln('usage: dart run portable_goldens:$usage '
      '[--goldens <pathspec>]   (default: $defaultGoldens)');
  exit(64);
}
