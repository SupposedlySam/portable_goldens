## 0.1.0

- `MachineGoldenComparator`: compares each golden exactly against this machine's render of the
  commit that last changed it, built on demand in a temporary git worktree and cached per user.
- A golden the branch changed passes against its own render and is reported with its diff
  against the committed image.
- `prepare` builds missing baselines; `report` lists failed and branch-changed goldens.
