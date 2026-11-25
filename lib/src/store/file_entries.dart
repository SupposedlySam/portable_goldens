import 'dart:io';

/// The last segment of [entity]'s path: its own name.
String nameOf(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

/// When [entity] was last modified, or null when it is not there.
DateTime? modifiedAt(FileSystemEntity entity) {
  final stat = entity.statSync();
  return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
}

/// What is in [dir], links not followed; nothing when it cannot be read,
/// such as when it was removed meanwhile.
List<FileSystemEntity> entriesOf(Directory dir) {
  try {
    return dir.listSync(followLinks: false);
  } on FileSystemException {
    return const [];
  }
}

/// The bytes the files at and under [path] take. A link counts as nothing:
/// what it points at is not in the folder, and may be anywhere.
int bytesUnder(String path) =>
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      FileSystemEntityType.file => _lengthOf(File(path)),
      FileSystemEntityType.directory => entriesOf(
        Directory(path),
      ).fold(0, (sum, entity) => sum + bytesUnder(entity.path)),
      _ => 0,
    };

int _lengthOf(File file) {
  try {
    return file.lengthSync();
  } on FileSystemException {
    return 0;
  }
}
