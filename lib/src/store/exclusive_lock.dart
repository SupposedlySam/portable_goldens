import 'dart:async';
import 'dart:io';

/// An exclusive lock on a file, across processes and within one.
///
/// Across processes, an advisory `fcntl` lock, which the OS releases when its
/// process dies, so a killed holder never leaves it held. Within one, an fcntl
/// lock belongs to the process, so a second taker in the same isolate would
/// get it at once; a map of the locks this isolate holds makes it wait.
final class ExclusiveLock {
  /// The lock on [file], which is created when missing.
  new(this.file);

  static final _held = <String, Completer<void>>{};

  /// The lock file.
  final File file;

  /// Runs [body] holding the lock, waiting for it first. Says once on stderr
  /// that it waits, since a build elsewhere can take minutes.
  Future<void> hold(Future<void> Function() body) async {
    for (var held = _held[file.path]; held != null; held = _held[file.path]) {
      await held.future;
    }
    await _holding(body, (handle) async {
      await _acquire(handle);
      return true;
    });
  }

  /// Runs [body] holding the lock when it is free now, and returns whether
  /// it ran: false, without waiting, when another process or this isolate
  /// holds it.
  Future<bool> tryHold(Future<void> Function() body) async {
    if (_held.containsKey(file.path)) return false;
    return await _holding(body, (handle) async {
      try {
        handle.lockSync(); // FileLock.exclusive
        return true;
      } on FileSystemException {
        return false;
      }
    });
  }

  // Runs [body] if [take] gets the lock on the file, and gives it back
  // after, however [body] ends.
  Future<bool> _holding(
    Future<void> Function() body,
    Future<bool> Function(RandomAccessFile handle) take,
  ) async {
    final done = Completer<void>();
    _held[file.path] = done;
    final handle = file.openSync(mode: FileMode.append);
    var taken = false;
    try {
      taken = await take(handle);
      if (taken) await body();
      return taken;
    } finally {
      if (taken) handle.unlockSync();
      handle.closeSync();
      _held.remove(file.path);
      done.complete();
    }
  }

  Future<void> _acquire(RandomAccessFile handle) async {
    var told = false;
    while (true) {
      try {
        handle.lockSync(); // FileLock.exclusive
        return;
      } on FileSystemException {
        if (!told) {
          stderr.writeln(
            'portable_goldens: waiting for another build of ${file.path}',
          );
          told = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }
}
