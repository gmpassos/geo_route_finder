import 'dart:typed_data';

/// Standard IEEE 802.3 CRC-32, used to verify the integrity of serialized
/// graph and index payloads. Implemented locally to keep the package free of
/// runtime dependencies.
class Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final t = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[i] = c;
    }
    return t;
  }

  /// Computes the CRC-32 of [bytes].
  static int compute(Uint8List bytes) {
    var crc = 0xFFFFFFFF;
    final table = _table;
    for (var i = 0; i < bytes.length; i++) {
      crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
