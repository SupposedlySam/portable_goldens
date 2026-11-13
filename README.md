# machine_goldens

Golden tests that compare each golden exactly against a baseline **this machine** rendered, so
two machines that draw the same widget a few pixels apart can both run the same goldens with no
tolerance.

## Why

Two Macs with the same Flutter, engine, Dart and `flutter_tester` binary rendered the same
widgets 1 to 20 pixels apart, at the anti-aliased edges of circles. The only difference between
them was the OS: macOS 26.6.2 (25G83) and macOS 27.2.1 (26B131). The goldens committed from one
failed on the other, all 19 of them.

A tolerance would hide that, and it would also hide a real 1-pixel regression. Instead, each
machine keeps its own baseline of every golden and compares exactly against it. The committed
pngs stay as they are: they are what a reviewer looks at, and what CI or a machine without git
compares against.

## Use

```yaml
dev_dependencies:
  machine_goldens: ^0.1.0
```

```dart
// test/flutter_test_config.dart
import 'dart:async';

import 'package:machine_goldens/machine_goldens.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  MachineGoldenComparator.install();
  await testMain();
}
```

`flutter test` finds `flutter_test_config.dart` by walking up from each test file, so one file
at `test/` covers every test. Nothing else changes: tests still call `matchesGoldenFile`.

### Before and after a run

```sh
dart run machine_goldens:prepare   # build every missing baseline now
flutter test                       # compare
dart run machine_goldens:report    # what failed, and what this branch changed
```

- **`prepare`** builds the baselines that are missing, one commit at a time, and prints the
  machine key and where the baselines live. Running it first is optional, because a test builds
  what it needs. It does keep the build time out of the test run, and it shows a failed build on
  its own rather than inside a test. It exits 1 if a build failed.
- **`report`** lists two groups:
  1. Each golden that **failed** against this machine's baseline, with the paths of its diff
     images.
  2. Each golden **changed by this branch**, with its diff against what it was before the
     branch, or "no diff".

  It exits 1 if anything failed.

Both take `--goldens <pathspec>`, a git pathspec relative to the package. The default is
`**/goldens/**/*.png`.

## How it works

### The machine key

The key holds everything that changes how this machine renders a golden:

| Value | Source |
|---|---|
| OS | `Platform.operatingSystem` |
| OS version and build | `Platform.operatingSystemVersion`, e.g. `Version 27.2.1 (Build 26B131)` |
| Architecture | `Abi.current()`, e.g. `macos_arm64` |
| Engine revision | see below |
| Framework revision | see below |
| Dart version | `Platform.version` |

A 16-hex-digit hash of those values (FNV-1a, 64-bit) names this machine's folder, and
`manifest.json` beside it records the readable values. When any value changes, after an OS
update say, the hash names a new folder. The baselines rendered before the change are never
found, so they are rebuilt rather than reused silently. A folder whose manifest names another
key (a collision, or a hand edit) is emptied.

On the two Macs above, the keys differ in the OS version and build alone. The M4 Pro and M4 Max
CPU models are not in the key: the OS already separated them.

**Engine revision.** It is read from `<flutter>/bin/cache/engine.stamp`, which the tool writes
when it downloads the engine artifacts. That file names the engine `flutter_tester` actually came
from. The fallback is `bin/internal/engine.version`, which is the engine the framework checkout
asks for; a checkout can change it before the cache catches up. `flutter --version --machine`
reports the same value, but it costs a process launch in every test file. The SDK is found from
`FLUTTER_ROOT`, which `flutter test` sets, or else from the running executable's path.

**Framework revision.** Text layout, painting and every widget are framework code, so a framework
commit on an unchanged engine, as on Flutter's main channel, can move pixels too. It is the commit
the SDK's git checkout is at, read from `.git/HEAD` and the ref it names, without launching git.
The fallback is `frameworkRevision` in `bin/cache/flutter.version.json`, which the tool writes.
Uncommitted edits to the framework are not seen.

When either revision cannot be found, every golden compares with the committed image, because an
update would otherwise go unnoticed.

### Where baselines live

The cache is per user and outside every repository, so it is never committed and every worktree
and clone shares it. A commit renders the same image wherever it is checked out on one machine.

| OS | Default |
|---|---|
| macOS | `~/Library/Caches/machine_goldens` |
| Linux | `$XDG_CACHE_HOME/machine_goldens`, or `~/.cache/machine_goldens` |
| Windows | `%LOCALAPPDATA%\machine_goldens` |

Set `MACHINE_GOLDENS_CACHE` to put it somewhere else. The layout:

```text
<cache>/<key id>/manifest.json            the key's readable values
<cache>/<key id>/<commit>/<unit>/         one commit's renders, for one package
<cache>/<key id>/<commit>/<unit>/.complete
<cache>/<key id>/<commit>/<unit>.lock     held while it is built
<cache>/<key id>/<commit>/<unit>.failed   the last build that failed
<cache>/<key id>/<commit>/.<unit>.tmp-*   a build in progress, and its checkout
```

The unit is the package's folder in its repository (`root` at the top), so two packages of one
monorepo never fill each other's folder. To reclaim space, delete a key folder; old OS versions
leave theirs behind.

### Which baseline a golden compares with

For each golden, the comparator decides in this order:

1. **The png differs from HEAD**: staged, unstaged or new. No commit has it to render, so it
   is compared exactly with the png in the working tree. That png is normally what
   `--update-goldens` just wrote on this machine, so the compare is still this machine against
   itself, and a render a pixel off it fails.
2. **Otherwise**, its baseline is this machine's render of `git log -1 --format=%H -- <png>`,
   the commit that last changed it. A png committed on this branch is no exception: its
   baseline is this machine's render of the branch's commit. The compare is exact:
   `GoldenFileComparator.compareLists`, every pixel equal. On failure, the diff images go to
   `failures/` beside the test, as with `LocalFileComparator`, and the message names the commit
   and the baseline's path.
3. **The committed image**, as a plain `LocalFileComparator` would compare. This is the fallback
   when there is no git, the package is outside a repository, the clone is shallow, no commit
   has the png, the commit cannot be checked out, no engine or framework revision is found, or
   the test runs inside a baseline build. The reason is printed once per test process. A shallow clone, as CI
   often makes, counts because its history stops at a boundary commit: `git log -1` names that
   commit for every png older than it, and its render is not what the png showed.

Whatever decided the test, a golden that passed and that this branch changed is recorded as
**changed by this branch**, with its diff against what it was before the branch, so a PR says
what moved. "Changed" means the png differs from the **merge-base** of HEAD with the default
branch, rather than from main's tip, because a main that has moved on would otherwise list other
people's goldens as this branch's. "Before the branch" is this machine's render of the commit
that last changed the png at the merge-base; when that commit does not build here, the diff is
against the png committed there instead, which another machine may have rendered. The diff is
information for the review, never a verdict.

The default branch is the newest merge-base among `origin/HEAD`, `origin/main`,
`origin/master`, `main` and `master`, so a stale `origin/main` beside a fresh local `main` does
not stretch the branch back past main. Set `MACHINE_GOLDENS_BASE` to a ref to choose another.
With none of them, only uncommitted changes count.

### Building a baseline

The first golden that needs a commit's baselines builds all of them at once:

1. Run `git worktree prune`, then `git worktree add --detach <checkout> <commit>`, with the
   repository's hooks off. The checkout is `.<unit>.tmp-<pid>-<time>-checkout`, beside the
   build's temporary folder in the cache.
2. Run `flutter pub get`, then `flutter test --update-goldens <files>` in the package. The files
   are the test files whose source contains `matchesGoldenFile`, or all of `test/` when none
   does.
3. Keep every png the run wrote, judged by mtime. The images checked out from git are never
   taken for renders. A golden the run did not write is a failure.
4. Remove the worktree.

The child run has `MACHINE_GOLDENS_CHILD=1` set and `FLUTTER_TEST` unset, so it compares with
the committed image and never builds in turn.

`flutter test` runs test files in parallel processes, and other worktrees may build the same
commit, so the build is safe to race:

- **A lock.** `<unit>.lock` takes an advisory `fcntl` lock, which the OS releases when its
  process dies. The second process waits for it, then finds the folder complete and builds
  nothing. If the first build failed while it waited, it gets that failure instead of running
  the build again.
- **Build, mark, rename.** The images and the `.complete` marker are written to a temporary
  folder, which is renamed into place in one atomic step. A folder without the marker is
  treated as missing and rebuilt, so a half-written baseline is never read as a good one, even
  where the lock does not hold. So is a folder whose marker does not parse, and an image the
  marker does not list.
- **A sweep.** A build killed before its own cleanup (by SIGKILL, say) leaves its temporary
  folder and checkout behind. The next build of that unit deletes every `.<unit>.tmp-*` under
  the lock, and its `git worktree prune` drops the dead checkout's registration. Killing a test
  process does not kill a `flutter test` it started: that orphan runs on in its checkout until
  the sweep deletes it or it finishes, and nothing reads what it wrote.
- **An atomic manifest.** Every test process opens the store at once, so `manifest.json` is
  written to a temporary file and renamed into place. A manifest that cannot be read is
  rewritten, and the baselines beside it are kept: only a readable manifest of another key
  empties the folder.

**A failed build fails the golden loudly.** The message names the commit, the command (in a form
that can be pasted into a shell) and the end of its output.

### `--update-goldens`

`flutter test --update-goldens` writes the committed png, as it always has. It does **not**
refresh the machine baseline, for two reasons:

- The updated png is now uncommitted, so rule 1 already applies: the png just written is its
  baseline, and `report` lists the golden with its diff against what it was before the branch.
- The machine baseline is keyed by the commit that last changed the png. Writing today's render
  under that old commit would make the commit's baseline disagree with what it renders, and
  every other worktree on the machine would then compare against it.

Once the png is committed, its new commit gets a baseline of its own the next time it is needed.

### Environment variables

| Variable | Meaning |
|---|---|
| `MACHINE_GOLDENS_CACHE` | Where the baselines live. |
| `MACHINE_GOLDENS_BASE` | The ref a branch's changes are measured from (its merge-base with HEAD). |
| `MACHINE_GOLDENS_CHILD` | Set to `1` inside a baseline build. Set by the package, not by you. |

Each test run records its outcomes under `.dart_tool/machine_goldens/report/` in the package,
which is where `report` reads them.

## Limits

- **A baseline build costs a test run.** It runs that commit's golden tests: about 18 seconds
  for 12 goldens in one measured repository. That cost is paid once per commit per machine
  key, and again after every OS, engine or Dart update.
- **A commit that no longer builds or passes** with today's SDK cannot produce a baseline, and
  its goldens fail with the command that failed. Re-render the png on the branch and commit it
  to move it to a commit that builds.
- **The key is measured, not proven.** The CPU model is left out because the OS version alone
  separated the two machines that prompted this package. If two machines with the same key ever
  render differently, the key needs another field.
- **The cache grows.** Nothing prunes old key folders or commits yet.

## Credit

The comparator follows [alchemist](https://pub.dev/packages/alchemist):

- `MachineGoldenComparator.install` wraps the comparator Flutter installed by resolving against
  its `basedir`, as `AlchemistFileComparator.fromExisting` does.
- It extends `LocalFileComparator` so failures keep the standard `failures/` output
  (`generateFailureOutput`).
- Alchemist's per-platform golden folders are the model for keeping a baseline per machine.

Alchemist's tolerance is deliberately not taken.
