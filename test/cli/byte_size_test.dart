import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/src/cli/byte_size.dart';

void main() {
  test('a size reads in powers of 1000, one decimal below 10', () {
    expect(byteSize(0), '0 B');
    expect(byteSize(999), '999 B');
    expect(byteSize(1000), '1.0 kB');
    expect(byteSize(1234), '1.2 kB');
    expect(byteSize(12345), '12 kB');
    expect(byteSize(3400000), '3.4 MB');
    expect(byteSize(5 * 1000 * 1000 * 1000 * 1000 * 1000), '5000 TB');
  });

  test('rounding never shows a figure the next unit up would', () {
    expect(byteSize(9960), '10 kB');
    expect(byteSize(999499), '999 kB');
    expect(byteSize(999950), '1.0 MB');
    expect(byteSize(999999999), '1.0 GB');
  });
}
