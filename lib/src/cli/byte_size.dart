/// [bytes] as a person reads a size: `512 B`, `1.2 kB`, `34 MB`.
///
/// In powers of 1000, as macOS and most file managers count, with one
/// decimal below 10 and none above. The figure is judged after rounding,
/// so 9,960 bytes is `10 kB`, not `10.0 kB`, and 999,950 is `1.0 MB`, not
/// `1000 kB`.
String byteSize(int bytes) {
  const units = ['B', 'kB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (true) {
    final digits = unit == 0 || _rounded(value, 1) >= 10 ? 0 : 1;
    final shown = _rounded(value, digits);
    if (shown < 1000 || unit == units.length - 1) {
      return '${shown.toStringAsFixed(digits)} ${units[unit]}';
    }
    value /= 1000;
    unit++;
  }
}

double _rounded(double value, int digits) =>
    double.parse(value.toStringAsFixed(digits));
