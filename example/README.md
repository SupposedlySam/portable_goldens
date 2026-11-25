# Example

portable_goldens has no app to run: it is installed once, in the test configuration Flutter loads
before every test file, and the tests stay as they are.

[`flutter_test_config.dart`](flutter_test_config.dart) is that file. Copy it to your package's
`test/` folder:

```dart
import 'dart:async';

import 'package:portable_goldens/portable_goldens.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PortableGoldenComparator.install();
  await testMain();
}
```

Then a golden test is the one you already have:

```dart
testWidgets('a dot', (tester) async {
  await tester.pumpWidget(const Center(child: Dot()));
  await expectLater(find.byType(Dot), matchesGoldenFile('goldens/dot.png'));
});
```

Render and commit it as usual (`flutter test --update-goldens`, then `git commit`). From then on
`flutter test` compares it exactly against this machine's render of that commit.

The package's `tool/consumer_workflow.sh` builds a consumer like this one from nothing and runs the
whole workflow, from the first golden to `prune`.
