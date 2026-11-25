# portable_goldens

Exact golden tests that pass on every machine. Each machine compares a golden against **its own
render** of the commit that last changed it, so two machines that draw the same widget a few
pixels apart can run the same committed goldens with no tolerance.

```text
  committed png  ──  what the reviewer sees; written by --update-goldens, as always
       │
       │  git log -1 -- <png>   →  commit C
       ▼
  render of C on THIS machine   ◄── exact compare ──►   render of HEAD on THIS machine
  (built once in a throwaway worktree, cached per machine)
```

## The problem

Goldens are only as portable as the renderer. Two Macs with the same Flutter, engine, Dart and
`flutter_tester` binary rendered the same widgets 1 to 20 pixels apart, at the anti-aliased
edges of circles. The only difference between them was the OS: macOS 26.6.2 (25G83) and macOS
27.2.1 (26B131). The goldens committed from one failed on the other, all 19 of them.

The usual answers each give something up:

| Approach | Examples on pub | What it costs |
|---|---|---|
| A pixel or perceptual **tolerance** | `golden_delicious`, `gleon`, alchemist's tolerance | A real 1-pixel regression passes too. |
| **Per-platform folders**, Ahem-font CI goldens | `alchemist` | One set of pngs per platform to keep up to date; CI goldens show boxes, not text; two Macs on different OS versions are still "one platform". |
| One **pinned environment** for every render | `golden_runner` (Docker) | Every golden run goes through a container, which still sometimes disagrees with CI. |
| **Compare only on one machine** | many suites in practice | Everyone else skips, or regenerates and commits noise. |

portable_goldens keeps the compare exact and the committed pngs unchanged, and moves the question
from "does this machine draw what that machine drew?" to "does this code draw what the code that
made the png drew, **here**?".

What follows from that:

- **No tolerance.** `GoldenFileComparator.compareLists`: every pixel equal, or it fails.
- **One set of pngs.** Nothing per platform, nothing per developer, nothing extra committed.
- **An OS, engine or Flutter upgrade does not churn the goldens.** The new environment gets its
  own baselines, rendered from the same commits, so only a change in *your* code fails a test.
- **A dependency upgrade that moves pixels is caught**, when the package commits its
  `pubspec.lock`: the baseline renders with the old commit's lock, the test with the new one.
- **Every worktree and clone on a machine shares one cache**, so a commit is rendered once per
  machine.

## Requirements

- Flutter 3.47 or later (Dart 3.13).
- `git` on the `PATH`, and the package inside a git repository with **full history**. A shallow
  clone, no git, or a package outside a repository falls back to the committed images (see
  [Fallbacks](#fallbacks)).
- macOS or Linux. Windows is not supported yet: path handling assumes `/`, so expect every golden
  there to fall back to the committed image.
- Tests that use `matchesGoldenFile` with Flutter's own `LocalFileComparator`. A package that
  swaps in its own comparator during each test, as alchemist's `goldenTest` does, takes the
  compare back from portable_goldens.

## Setup

```yaml
dev_dependencies:
  portable_goldens: ^0.1.0
```

```dart
// test/flutter_test_config.dart
import 'dart:async';

import 'package:portable_goldens/portable_goldens.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PortableGoldenComparator.install();
  await testMain();
}
```

`flutter test` finds `flutter_test_config.dart` by walking up from each test file, so one file at
`test/` covers every test. Nothing else changes: tests still call `matchesGoldenFile`, and
`--update-goldens` still writes the committed pngs.

`install()` replaces only the plain `LocalFileComparator` that `flutter test` sets. If something
else is in place when it runs, such as another package's comparator or your own subclass of
`LocalFileComparator`, it leaves that comparator alone and prints once, on stderr, that goldens
compare with it and not with machine baselines. Pass `strict: true` to make that an error
instead, so a suite cannot run with goldens that are not machine-checked:

```dart
PortableGoldenComparator.install(strict: true); // throws a StateError if it cannot install
```

Calling `install()` again is a no-op.

## Day to day

```sh
dart run portable_goldens:prepare   # optional: build every missing baseline now
flutter test                       # compare
dart run portable_goldens:report    # what failed, and what this branch changed
dart run portable_goldens:verify    # before pushing: can each commit draw its own png?
```

**Changing a widget on purpose.** Run `flutter test --update-goldens`, look at the new pngs,
commit them. Until they are committed they compare against themselves in the working tree; once
committed, their new commit is the baseline. `report` lists each one as *changed by this branch*
with a diff against what it was before the branch, which is what a reviewer wants to see.

**A golden fails.** The message says what it was compared with (this machine's render of commit
`C`, the working-tree png, or the committed image and why) and where Flutter wrote the diff
images, in `failures/` beside the test as usual. `report` lists every failure from the last run.

**A baseline build fails.** The golden fails loudly with the commit, the command (ready to paste
into a shell) and the end of its output. The usual cause is an old commit that no longer builds
with today's SDK. Re-render the png on your branch and commit it: its baseline moves to a commit
that builds.

**Before pushing.** `verify` checks that each png the branch committed is what its commit draws
on this machine. A png committed before its last code change, or with only part of the code
(`git add -p`, a rebase that split a commit), is a picture no commit can draw, and nothing else
notices: every machine compares the golden with its commit's render, not with the png. Run it on
the machine that rendered the pngs, since anywhere else every png differs by the machine too.

**After an OS or Flutter update.** The first run rebuilds the baselines it needs, one test run per
commit. Run `prepare` once to pay that up front.

### `prepare`

Builds the baselines that are missing, one commit at a time, and prints the machine key and where
the baselines live. It is optional, because a test builds what it needs, but it keeps the build
time out of the test run and shows a failed build on its own rather than inside a test. It exits
1 if a build failed, or if a build passed without writing a golden it should have: it asks the
store again before it says every baseline is in place.

### `report`

Reads what the last test run recorded and lists two groups:

1. Each golden that **failed**, against this machine's baseline or against the committed image or
   working-tree png it fell back to, with the paths of its diff images.
2. Each golden **changed by this branch**, with its diff against what it was before the branch, or
   "no diff". A golden the run did not compare says "not compared yet".

It exits 1 if anything failed. With `--json` it writes the same two groups as one JSON document,
for tools:

```json
{
  "base": "<the commit the branch is measured from>",
  "failed": [{"golden": "test/goldens/b.png", "diffs": ["<path of a diff image>"]}],
  "changed": [
    {"golden": "test/goldens/a.png", "compared": true, "baseline": "<what it was compared with>", "diffs": ["..."]},
    {"golden": "test/goldens/c.png", "compared": false, "diffs": []}
  ]
}
```

### `verify`

For each golden the branch changed (every tracked golden with `--all`), renders the commit that
last changed it, building the baseline if it is missing, and compares that render with the png
the commit holds, pixel for pixel, with the compare `matchesGoldenFile` uses. A png changed in the
working tree is checked as HEAD has it. Each golden is one of:

- **verified**: the png is exactly what its commit draws here;
- **MISMATCH**: it is not. The committed png, the render and the diff images are kept in
  `.dart_tool/portable_goldens/verify/mismatches/<golden>/`, and the message names the commit;
- **UNBUILT**: the commit's baselines failed to build, so there is nothing to check against;
- **NOT CHECKED**: it could not be checked, and says why (the pixel compare failed to run, say);
- **uncommitted**: a new png with no commit yet, which is not a failure.

It exits 1 on anything but verified or uncommitted: a check that did not run is not a pass. It
also exits 1, without checking, where machine baselines do not apply (a shallow clone, no git).
The pixel compare needs a Flutter test binding, so it runs as one generated `flutter test` in
`.dart_tool/portable_goldens/verify/`, for every png whose bytes differ from its render. With
`--json` it writes `{"machine", "passed", "checks": [{"golden", "result", ...}]}`, for tools.

As a git pre-push hook, in `.git/hooks/pre-push`:

```sh
#!/bin/sh
cd path/to/package && dart run portable_goldens:verify
```

### Options every command takes

Every command takes `--goldens <pathspec>` (or `--goldens=<pathspec>`), a git pathspec relative
to the package. The default is `**/goldens/**/*.png`. Run them from the package's root. `--help`
prints a command's usage. An option a command does not take exits 64, with the usage. Inside a
baseline build every command refuses and exits 1, since it would build from within a build.

## In CI

CI is one more machine. Give it what a laptop has:

```yaml
# GitHub Actions
- uses: actions/checkout@v4
  with:
    fetch-depth: 0               # full history: a shallow clone falls back to the committed images
- uses: actions/cache@v4
  with:
    path: ~/.cache/portable_goldens
    key: machine-goldens-${{ runner.os }}-${{ hashFiles('**/goldens/**/*.png') }}
    restore-keys: machine-goldens-${{ runner.os }}-
- run: dart run portable_goldens:prepare
- run: flutter test
- run: dart run portable_goldens:report
```

Without the cache, every run renders every baseline it needs: one `flutter test` of the golden
files for each distinct commit that last changed a golden. With it, a run renders only the commits
new since the cached one. The cache key may be anything; the machine key inside the cache already
keeps one runner image's renders apart from another's.

With a shallow clone, CI compares with the committed images like a plain `flutter test`, and
says so once per test process.

## How it works

### Which baseline a golden compares with

For each golden, in this order:

1. **The png differs from HEAD**: staged, unstaged or new. No commit has it to render, so it is
   compared exactly with the png in the working tree. That png is normally what
   `--update-goldens` just wrote on this machine, so the compare is still this machine against
   itself, and a render a pixel off it fails.
2. **Otherwise**, its baseline is this machine's render of `git log -1 --format=%H -- <png>`, the
   commit that last changed it. A png committed on this branch is no exception: its baseline is
   this machine's render of the branch's commit. On failure, the diff images go to `failures/`
   beside the test, as with `LocalFileComparator`, and the message names the commit and the
   baseline's path.
3. **The committed image**, as a plain `LocalFileComparator` would compare. See
   [Fallbacks](#fallbacks).

Whatever decided the test, a golden that passed and that this branch changed is recorded as
**changed by this branch**, with its diff against what it was before the branch, so a PR says
what moved. "Changed" means the png differs from the **merge-base** of HEAD with the default
branch, rather than from main's tip, because a main that has moved on would otherwise list other
people's goldens as this branch's. "Before the branch" is this machine's render of the commit
that last changed the png at the merge-base; when that commit does not build here, the diff is
against the png committed there instead, which another machine may have rendered. The diff is
information for the review, never a verdict.

The default branch is the newest merge-base among `origin/HEAD`, `origin/main`, `origin/master`,
`main` and `master`, so a stale `origin/main` beside a fresh local `main` does not stretch the
branch back past main. Set `PORTABLE_GOLDENS_BASE` to a ref to choose another. With none of them,
only uncommitted changes count.

### Fallbacks

A golden compares with the committed image when any of these holds, and the reason is printed
once per test process:

- there is no git, or the package is outside a repository;
- the clone is shallow: its history stops at a boundary commit, `git log -1` names that commit for
  every png older than it, and its render is not what the png showed;
- no commit has the png;
- the commit cannot be checked out;
- the Flutter engine or framework revision cannot be found, because an SDK update would then go
  unnoticed;
- the test runs inside a baseline build.

### The machine key

The key holds everything that changes how this machine renders a golden:

| Value | Source |
|---|---|
| OS | `Platform.operatingSystem` |
| OS version and build | `Platform.operatingSystemVersion`, e.g. `Version 27.2.1 (Build 26B131)` |
| Architecture | `Abi.current()`, e.g. `macos_arm64` |
| Engine revision | `<flutter>/bin/cache/engine.stamp`, else `bin/internal/engine.version` |
| Framework revision | the SDK checkout's `.git/HEAD`, else `bin/cache/flutter.version.json` |
| Dart version | `Platform.version` |

A 16-hex-digit hash of those values (FNV-1a, 64-bit) names this machine's folder, and
`manifest.json` beside it records the readable values. When any value changes, the hash names a
new folder, so baselines rendered before the change are never reused. A folder whose manifest
names another key (a collision, or a hand edit) is emptied.

On the two Macs above, the keys differ in the OS version and build alone. The M4 Pro and M4 Max
CPU models are not in the key: the OS already separated them.

**Engine revision.** `engine.stamp` is written by the tool when it downloads the engine
artifacts, so it names the engine `flutter_tester` actually came from. `engine.version` is the
engine the framework checkout asks for, which a checkout can change before the cache catches up.
`flutter --version --machine` reports the same value, but costs a process launch in every test
file. The SDK is found from `FLUTTER_ROOT`, which `flutter test` sets, or else from the running
executable's path.

**Framework revision.** Text layout, painting and every widget are framework code, so a framework
commit on an unchanged engine, as on Flutter's main channel, can move pixels too. It is read from
`.git/HEAD` and the ref it names, without launching git. Uncommitted edits to the framework are
not seen.

### Where baselines live

The cache is per user and outside every repository, so it is never committed and every worktree
and clone shares it.

| OS | Default |
|---|---|
| macOS | `~/Library/Caches/portable_goldens` |
| Linux | `$XDG_CACHE_HOME/portable_goldens`, or `~/.cache/portable_goldens` |

Set `PORTABLE_GOLDENS_CACHE` to put it somewhere else. The layout:

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

### Building a baseline

The first golden that needs a commit's baselines builds all of them at once:

1. Run `git worktree prune`, then `git worktree add --detach <checkout> <commit>`, with the
   repository's hooks off. The checkout is `.<unit>.tmp-<pid>-<time>-checkout`, beside the build's
   temporary folder in the cache.
2. Run `flutter pub get`, then `flutter test --update-goldens <files>` in the package, with the
   same SDK as the test. The files are the commit's own test files whose source contains
   `matchesGoldenFile`, or all of `test/` when none does.
3. Keep every png the run wrote, judged by mtime. The images checked out from git are never taken
   for renders. A golden the run did not write is a failure.
4. Remove the worktree.

The child run has `PORTABLE_GOLDENS_CHILD=1` set and `FLUTTER_TEST` unset, so it compares with the
committed image and never builds in turn.

`flutter test` runs test files in parallel processes, and other worktrees may build the same
commit, so the build is safe to race:

- **A lock.** `<unit>.lock` takes an advisory `fcntl` lock, which the OS releases when its process
  dies. The second process waits for it, then finds the folder complete and builds nothing. If the
  first build failed while it waited, it gets that failure instead of running the build again.
- **Build, mark, rename.** The images and the `.complete` marker are written to a temporary
  folder, which is renamed into place in one atomic step. A folder without the marker is treated
  as missing and rebuilt, so a half-written baseline is never read as a good one, even where the
  lock does not hold. So is a folder whose marker does not parse, and an image the marker does not
  list.
- **A sweep.** A build killed before its own cleanup (by SIGKILL, say) leaves its temporary folder
  and checkout behind. The next build of that unit deletes every `.<unit>.tmp-*` under the lock,
  and its `git worktree prune` drops the dead checkout's registration. Killing a test process does
  not kill a `flutter test` it started: that orphan runs on in its checkout until the sweep
  deletes it or it finishes, and nothing reads what it wrote.
- **An atomic manifest.** Every test process opens the store at once, so `manifest.json` is
  written to a temporary file and renamed into place. A manifest that cannot be read is rewritten,
  and the baselines beside it are kept: only a readable manifest of another key empties the
  folder.

### `--update-goldens`

`flutter test --update-goldens` writes the committed png, as it always has. It does **not**
refresh the machine baseline, for two reasons:

- The updated png is now uncommitted, so rule 1 already applies: the png just written is its
  baseline, and `report` lists the golden with its diff against what it was before the branch.
- The machine baseline is keyed by the commit that last changed the png. Writing today's render
  under that old commit would make the commit's baseline disagree with what it renders, and every
  other worktree on the machine would then compare against it.

Once the png is committed, its new commit gets a baseline of its own the next time it is needed.

### The report's records

Each test run records its outcomes under `.dart_tool/portable_goldens/report/` in the package,
which is where `report` reads them. The first write of a test process deletes the entries an
earlier run left, so a golden fixed or deleted since is not listed. A run is told apart by the
`flutter test` process all its test files share, its pid and start time, asked of `ps`.

## Environment variables

| Variable | Meaning |
|---|---|
| `PORTABLE_GOLDENS_CACHE` | Where the baselines live. |
| `PORTABLE_GOLDENS_BASE` | The ref a branch's changes are measured from (its merge-base with HEAD). |
| `PORTABLE_GOLDENS_CHILD` | Set to `1` inside a baseline build. Set by the package, not by you. |

## Libraries

- `package:portable_goldens/portable_goldens.dart`: `PortableGoldenComparator`, for
  `flutter_test_config.dart`. Exports everything below too.
- `package:portable_goldens/baselines.dart`: the machinery in plain Dart, without `flutter_test`,
  for tools built on it: `MachineKey`, `BaselineStore`, `BaselineBuilder`, `MachineGoldens` (which
  baseline a golden uses, what is missing, what the branch changed), `GoldenReport`, and
  `GoldenVerifier` with its `PixelComparer`.

## Limits

- **A baseline build costs a test run.** It runs that commit's golden tests: about 18 seconds for
  12 goldens in one measured repository. That cost is paid once per commit per machine key, and
  again after every OS, engine, framework or Dart update.
- **A commit that no longer builds or passes** with today's SDK cannot produce a baseline, and its
  goldens fail with the command that failed. Re-render the png on the branch and commit it to move
  it to a commit that builds.
- **The key is measured, not proven.** The CPU model is left out because the OS version alone
  separated the two machines that prompted this package. If two machines with the same key ever
  render differently, the key needs another field.
- **Only `verify` checks a committed png against its own commit's code.** The baseline is what the
  commit renders here, never the png it committed, so a png committed stale (re-rendered before a
  last code change, say) passes the tests on every machine. `verify` catches it, but only when run
  on the machine that rendered the png, and only if someone runs it: nothing runs it for you.
  `report` does not flag a render that differs from the committed png: on any machine but the one
  that rendered it, every golden differs from it, so the flag would be noise.
- **The committed pngs drift from every machine but the last to render them.** That is by design
  locally, but it means a run that falls back to the committed images (a shallow CI clone, say)
  can fail where a full clone passes.
- **A dependency change is caught only when the lock is committed.** Without a `pubspec.lock` at
  the commit, its baseline resolves today's dependencies, the same as the test.
- **The cache grows.** Nothing prunes old key folders or commits yet.

## Credit

The comparator follows [alchemist](https://pub.dev/packages/alchemist):

- `PortableGoldenComparator.install` wraps the comparator Flutter installed by resolving against
  its `basedir`, as `AlchemistFileComparator.fromExisting` does.
- It extends `LocalFileComparator` so failures keep the standard `failures/` output
  (`generateFailureOutput`).
- Alchemist's per-platform golden folders are the model for keeping a baseline per machine.

Alchemist's tolerance is deliberately not taken.
