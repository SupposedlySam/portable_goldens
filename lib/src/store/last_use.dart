import 'dart:io';

/// Records that [file] was used now, as its modification time, once per
/// process: the time `prune` reads to tell baselines in use from ones
/// nobody has needed for a while.
///
/// The file's modification time, not its access time, which most systems
/// update lazily or not at all (`noatime`, `relatime`). Once per process,
/// since a test process reads a baseline per golden and a day is the finest
/// grain prune judges by. A cache that cannot be written to is used all the
/// same: the time is a hint for prune, never a reason to fail a test.
void recordUse(File file) {
  if (!_recorded.add(file.path)) return;
  try {
    file.setLastModifiedSync(DateTime.now());
  } on FileSystemException {
    // Read-only, or removed meanwhile: prune sees the older time.
  }
}

final _recorded = <String>{};
