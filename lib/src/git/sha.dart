/// The first ten characters of a commit [sha], as messages print it.
String shortSha(String sha) => sha.length > 10 ? sha.substring(0, 10) : sha;
