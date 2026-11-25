## 0.1.0

- `PortableGoldenComparator`: compares each golden exactly against this machine's render of the
  commit that last changed it, built on demand in a temporary git worktree and cached per user.
- `install()` replaces only `flutter test`'s own `LocalFileComparator`, says once on stderr when
  another comparator is in place, and with `strict: true` throws instead.
- A png that differs from HEAD compares exactly with itself in the working tree; a golden the
  branch changed is reported with its diff against what it was before the branch.
- `prepare` builds missing baselines; `report` lists failed and branch-changed goldens, and
  `report --json` writes them for tools. Every command takes `--help`.
- `verify` checks that each committed png is what its own commit draws on this machine, with the
  compare `matchesGoldenFile` uses, and keeps the images of a mismatch. `--all` checks every
  tracked golden; `--json` writes the checks for tools. A failure against this machine's baseline
  points at it.
- A baseline build checks out the commit's submodules, and gives its checkout the path
  dependencies outside the repository, by absolute path in a generated `pubspec_overrides.yaml`,
  as this machine resolves them.
- Goldens in Git LFS: a commit's png is read through the commit's own filters, so it is the image
  wherever `git lfs` is installed. A pointer is never compared: the test fails naming it, and
  `verify` reports it as not checked. `GitRepo.show` and `MachineGoldens.committedImage` return a
  `CommittedFile`: the bytes, or an `UnknownFile` (`LfsPointer`, `UnreadFile`) saying why not.
