import 'dart:io';

/// The environment variable that moves the cache.
const cacheEnvironmentVariable = 'PORTABLE_GOLDENS_CACHE';

/// Where baselines live when [cacheEnvironmentVariable] is not set: the
/// user's cache folder, outside every repository.
///
/// One folder per user, not per checkout, so every worktree and clone of a
/// repository shares the baselines: they are keyed by commit, and a commit
/// renders the same image wherever it is checked out on the same machine.
String defaultCacheRoot({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  if (env[cacheEnvironmentVariable] case final override?
      when override.isNotEmpty) {
    return override;
  }
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  if (Platform.isMacOS) return '$home/Library/Caches/portable_goldens';
  if (Platform.isWindows) {
    final local = env['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    return '$local\\portable_goldens';
  }
  final xdg = env['XDG_CACHE_HOME'];
  final cache = xdg != null && xdg.isNotEmpty ? xdg : '$home/.cache';
  return '$cache/portable_goldens';
}
