import 'dart:convert';

/// A stable 16-hex-digit hash of [text], for naming a cache folder.
///
/// FNV-1a, 64-bit: a folder name needs a stable short hash, not a
/// cryptographic one. Whatever a folder is named after is also kept readable
/// beside it (a machine key's manifest, a build's marker), and a mismatch
/// there throws the folder away, so a collision cannot reuse a baseline.
///
/// The constants do not fit a JavaScript number; this package runs only on
/// the Dart VM (it needs dart:io and dart:ffi), whose ints are 64-bit.
String shortHash(String text) {
  // The VM's 64-bit ints, as above.
  // ignore: avoid_js_rounded_ints
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  // An int is signed, so each 32-bit half is written on its own.
  String half(int value) =>
      (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${half(hash >> 32)}${half(hash)}';
}
