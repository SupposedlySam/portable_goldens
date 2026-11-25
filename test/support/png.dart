import 'dart:io';
import 'dart:typed_data';

/// A [width] by [height] RGBA png whose every pixel is [pixel] (0xRRGGBBAA),
/// except those [at] gives; [level] is the zlib level, so two encodings of
/// the same pixels can differ in bytes.
List<int> encodePng(
  int width,
  int height, {
  int pixel = 0xffffffff,
  Map<(int, int), int> at = const {},
  int level = 6,
}) {
  final rows = BytesBuilder();
  for (var y = 0; y < height; y++) {
    rows.addByte(0); // no filter
    for (var x = 0; x < width; x++) {
      final rgba = at[(x, y)] ?? pixel;
      rows.add(
        [rgba >> 24, rgba >> 16, rgba >> 8, rgba].map((b) => b & 0xff).toList(),
      );
    }
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // RGBA
  return [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    ..._chunk('IHDR', header.buffer.asUint8List()),
    ..._chunk('IDAT', ZLibCodec(level: level).encode(rows.takeBytes())),
    ..._chunk('IEND', const []),
  ];
}

List<int> _chunk(String type, List<int> data) {
  final typed = [...type.codeUnits, ...data];
  return [..._uint32(data.length), ...typed, ..._uint32(_crc32(typed))];
}

List<int> _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
