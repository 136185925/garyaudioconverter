import 'dart:io';
import 'dart:typed_data';

class WavMetadata {
  const WavMetadata({
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.frames,
    required this.fileBytes,
  });

  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final int frames;
  final int fileBytes;

  int get outputSampleRate => sampleRate * 4;
  Duration get duration =>
      Duration(milliseconds: (frames * 1000 / sampleRate).round());

  static Future<WavMetadata> read(String path) async {
    final file = File(path);
    final handle = await file.open();
    try {
      final fileBytes = await handle.length();
      if (fileBytes < 44) {
        throw const WavMetadataException('The file is too short to be WAV.');
      }
      final riff = await _readExact(handle, 12);
      if (_ascii(riff, 0, 4) != 'RIFF' || _ascii(riff, 8, 4) != 'WAVE') {
        throw const WavMetadataException('Not a RIFF/WAVE file.');
      }

      int? channels;
      int? sampleRate;
      int? blockAlign;
      int? bitsPerSample;
      int? formatTag;
      var extensiblePcm = false;
      int? dataBytes;
      var position = 12;

      while (position + 8 <= fileBytes &&
          (channels == null || dataBytes == null)) {
        await handle.setPosition(position);
        final header = await _readExact(handle, 8);
        final id = _ascii(header, 0, 4);
        final chunkBytes = _u32(header, 4);
        final chunkStart = position + 8;
        if (id == 'fmt ') {
          if (chunkBytes < 16) {
            throw const WavMetadataException('Incomplete WAV format chunk.');
          }
          final format = await _readExact(handle, chunkBytes.clamp(16, 64));
          formatTag = _u16(format, 0);
          channels = _u16(format, 2);
          sampleRate = _u32(format, 4);
          blockAlign = _u16(format, 12);
          bitsPerSample = _u16(format, 14);
          extensiblePcm =
              formatTag == 0xfffe &&
              format.length >= 40 &&
              _u16(format, 24) == 1;
        } else if (id == 'data') {
          dataBytes = chunkBytes;
        }
        position = chunkStart + chunkBytes + (chunkBytes.isOdd ? 1 : 0);
      }

      if (channels == null ||
          sampleRate == null ||
          blockAlign == null ||
          bitsPerSample == null ||
          dataBytes == null) {
        throw const WavMetadataException(
          'The WAV format or audio chunk is missing.',
        );
      }
      if (formatTag != 1 && !extensiblePcm) {
        throw const WavMetadataException(
          'Only uncompressed PCM WAV files are supported.',
        );
      }
      if (bitsPerSample != 16 && bitsPerSample != 24) {
        throw const WavMetadataException(
          'Input must use 16-bit or packed 24-bit PCM.',
        );
      }
      if (sampleRate != 44100 && sampleRate != 48000) {
        throw const WavMetadataException(
          'Input sample rate must be 44.1 kHz or 48 kHz.',
        );
      }
      if (channels < 1 ||
          channels > 8 ||
          blockAlign != channels * (bitsPerSample ~/ 8)) {
        throw const WavMetadataException('Unsupported WAV channel layout.');
      }

      return WavMetadata(
        channels: channels,
        sampleRate: sampleRate,
        bitsPerSample: bitsPerSample,
        frames: dataBytes ~/ blockAlign,
        fileBytes: fileBytes,
      );
    } finally {
      await handle.close();
    }
  }

  static Future<Uint8List> _readExact(RandomAccessFile file, int count) async {
    final bytes = await file.read(count);
    if (bytes.length != count) {
      throw const WavMetadataException('Unexpected end of WAV file.');
    }
    return bytes;
  }

  static String _ascii(Uint8List bytes, int offset, int count) =>
      String.fromCharCodes(bytes.sublist(offset, offset + count));

  static int _u16(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes).getUint16(offset, Endian.little);

  static int _u32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes).getUint32(offset, Endian.little);
}

class WavMetadataException implements Exception {
  const WavMetadataException(this.message);

  final String message;

  @override
  String toString() => message;
}
