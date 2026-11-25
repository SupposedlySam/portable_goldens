#!/usr/bin/env bash
# Runs the README's workflow as a consumer would, end to end.
#
# Builds a small Flutter package in a new git repository, depending on this
# checkout by path, with test/flutter_test_config.dart copied from example/,
# then runs what the README says to run: render and commit a golden,
# prepare, flutter test, report, verify --all, prune. Each must exit 0.
#
# A pass that is silence proves nothing, so it also changes the widget's
# colour without re-rendering the png, and requires that flutter test and
# report then FAIL, and that the failure names this machine's baseline. That
# shows the compare ran against a baseline, not a fallback.
#
# The cache is a temporary folder, never the user's. The consumer depends on
# this checkout from outside its repository, so the baseline build also
# exercises the generated pubspec_overrides.yaml.
#
# The widget imports a generated file that git ignores, as code from
# build_runner would be, so a baseline compiles only if the
# `portable_goldens: setup:` step in the consumer's pubspec runs, with the
# SDK's `dart` on its PATH, before the tests.
#
# What it does not cover: a second machine (the cross-machine claim is the
# key's, and needs two machines), Git LFS, submodules, and a shallow clone.
set -euo pipefail

# A path as the Dart tools read it. Git Bash on Windows writes `/d/a/...`,
# which only its own programs understand; `cygpath -m` gives `D:/a/...`,
# which both sides do. Elsewhere a path is already that.
native() {
  if command -v cygpath > /dev/null; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

package="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/portable_goldens_consumer.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
consumer="$work/consumer"
cache="$work/cache"
export PORTABLE_GOLDENS_CACHE="$(native "$cache")"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nconsumer workflow FAILED: %s\n' "$*" >&2; exit 1; }

step "A consumer package in $consumer"
mkdir -p "$consumer/lib" "$consumer/test"
cat > "$consumer/pubspec.yaml" <<EOF
name: consumer
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
  portable_goldens:
    path: $(native "$package")
portable_goldens:
  setup:
    - dart run tool/generate.dart
EOF
mkdir -p "$consumer/tool"
cat > "$consumer/tool/generate.dart" <<'EOF'
import 'dart:io';

void main() => File('lib/dot_shape.g.dart').writeAsStringSync(
  "import 'package:flutter/widgets.dart';\n\nconst dotShape = BoxShape.circle;\n",
);
EOF
cat > "$consumer/lib/dot.dart" <<'EOF'
import 'package:flutter/widgets.dart';

import 'dot_shape.g.dart';

const dotColor = Color(0xFF2196F3);

class Dot extends StatelessWidget {
  const Dot({super.key});

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(color: dotColor, shape: dotShape),
  );
}
EOF
cat > "$consumer/test/dot_test.dart" <<'EOF'
import 'package:consumer/dot.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a dot', (tester) async {
    await tester.pumpWidget(
      const Center(
        child: RepaintBoundary(
          child: SizedBox(width: 64, height: 64, child: Dot()),
        ),
      ),
    );
    await expectLater(
      find.byType(RepaintBoundary).first,
      matchesGoldenFile('goldens/dot.png'),
    );
  });
}
EOF
cp "$package/example/flutter_test_config.dart" "$consumer/test/"
printf '.dart_tool/\nbuild/\npubspec.lock\n*.g.dart\n' > "$consumer/.gitignore"

cd "$consumer"
git init --quiet
git config user.email consumer@example.com
git config user.name Consumer
git config commit.gpgsign false
flutter pub get
dart run tool/generate.dart
git check-ignore --quiet lib/dot_shape.g.dart ||
  fail 'git does not ignore the generated file, so the setup step proves nothing'
git add -A
git commit --quiet -m 'a dot'

step 'flutter test --update-goldens, and commit the png'
flutter test --update-goldens
[[ -f test/goldens/dot.png ]] || fail 'no golden was written'
git add -A
git commit --quiet -m 'the golden'

step 'prepare'
dart run portable_goldens:prepare || fail 'prepare'
compgen -G "$cache/*/*/root@*/test/goldens/dot.png" > /dev/null ||
  fail 'no baseline was built under a unit named for the setup step'

step 'flutter test'
flutter test > "$work/test.txt" 2>&1 || { cat "$work/test.txt"; fail 'flutter test'; }
cat "$work/test.txt"

step 'report'
dart run portable_goldens:report || fail 'report'

step 'verify --all'
dart run portable_goldens:verify --all || fail 'verify --all'

step 'A widget change the png does not have must fail, against the baseline'
sed -i.orig 's/0xFF2196F3/0xFFF44336/' lib/dot.dart
grep -q 0xFFF44336 lib/dot.dart || fail 'the colour was not changed'
if flutter test > "$work/changed.txt" 2>&1; then
  cat "$work/changed.txt"
  fail 'flutter test passed with a widget the golden does not show'
fi
grep -q "this machine's baseline" "$work/changed.txt" ||
  { cat "$work/changed.txt"; fail 'the failure did not compare with a baseline'; }
if dart run portable_goldens:report; then
  fail 'report exited 0 after a failed golden'
fi
mv lib/dot.dart.orig lib/dot.dart

step 'flutter test passes again'
flutter test || fail 'flutter test after restoring the widget'

step 'prune --dry-run, then prune'
dart run portable_goldens:prune --dry-run || fail 'prune --dry-run'
dart run portable_goldens:prune || fail 'prune'

printf '\nconsumer workflow passed.\n'
