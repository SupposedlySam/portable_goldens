## 0.1.0

- `PortableGoldenComparator`: compares each golden exactly against this machine's render of the
  commit that last changed it, built on demand in a temporary git worktree and cached per user.
- `install()` replaces only `flutter test`'s own `LocalFileComparator`, says once on stderr when
  another comparator is in place, and with `strict: true` throws instead.
- A png that differs from HEAD compares exactly with itself in the working tree; a golden the
  branch changed is reported with its diff against what it was before the branch.
- `prepare` builds missing baselines; `report` lists failed and branch-changed goldens, and
  `report --json` writes them for tools. Every `--json` document carries its `schema` and
  `version`. Every command takes `--help`.
- `verify` checks that each committed png is what its own commit draws on this machine, with the
  compare `matchesGoldenFile` uses, and keeps the images of a mismatch. `--all` checks every
  tracked golden; `--json` writes the checks for tools. A failure against this machine's baseline
  points at it.
- A golden compared with its committed image says why with a typed `FallbackReason`
  (`SessionFallback`, `GoldenFallback`, `CheckoutFailed`), which prints as a phrase.
- `prune` removes the baselines nobody needs: ones unused for 30 days (`--older-than`), in any
  repository and under any machine key, and ones of commits no branch, tag or checkout of the
  repository has, once unused for a day. A commit the repository does not have goes by age alone,
  the cache being shared. `--dry-run` removes nothing. Reading a baseline and opening the store
  record their use, as modification times.
- A baseline build checks out the commit's submodules, and gives its checkout the path
  dependencies outside the repository, by absolute path in a generated `pubspec_overrides.yaml`,
  as this machine resolves them. It runs none of the repository's git hooks.
- Goldens in Git LFS: a commit's png is read through the commit's own filters, so it is the image
  wherever `git lfs` is installed. A pointer is never compared: the test fails naming it, and
  `verify` reports it as not checked. `GitRepo.show` and `MachineGoldens.committedImage` return a
  `CommittedFile`: the bytes, or an `UnknownFile` (`LfsPointer`, `UnreadFile`) saying why not.
  CI runs the README's workflow with the pngs in Git LFS on each OS.
- Runs on macOS, Linux and Windows, all three checked in CI. On Windows a setup step is the one
  line of a batch file, so a literal `%` is written `%%`.
- Setup steps: `portable_goldens: setup:` in the package's `pubspec.yaml` lists commands (a
  `build_runner` build, `flutter gen-l10n`) that a baseline build runs after `flutter pub get`,
  so ignored generated code exists in its checkout. Their hash is part of the baseline's folder
  name, and a configuration that cannot be read fails with `SetupConfigError` naming the file.
