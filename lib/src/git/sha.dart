/// The first ten characters of a commit [sha], as messages print it.
String shortSha(String sha) => sha.length > 10 ? sha.substring(0, 10) : sha;

/// Whether [name] is a whole commit id as git writes one: 40 hex digits,
/// or 64 in a repository that uses SHA-256.
bool isFullSha(String name) => _fullSha.hasMatch(name);

final _fullSha = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');
