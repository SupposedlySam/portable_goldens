## 0.1.0

- `MachineGoldenComparator`: compares each golden exactly against this machine's render of the
  commit that last changed it, built on demand in a temporary git worktree and cached per user.
- A png that differs from HEAD compares exactly with itself in the working tree; a golden the
  branch changed is reported with its diff against what it was before the branch.
- `prepare` builds missing baselines; `report` lists failed and branch-changed goldens.
