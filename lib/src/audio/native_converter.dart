import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import '../models/conversion_job.dart';

typedef _NativeConvert =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Int32,
      Int32,
      Double,
      Int32,
      Int32,
      Int32,
    );
typedef _DartConvert =
    int Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
      int,
      double,
      int,
      int,
      int,
    );
typedef _NativeProgress = Double Function();
typedef _DartProgress = double Function();
typedef _NativeCancel = Void Function();
typedef _DartCancel = void Function();
typedef _NativeCopyError = Int32 Function(Pointer<Utf16>, Int32);
typedef _DartCopyError = int Function(Pointer<Utf16>, int);

class NativeConversionResult {
  const NativeConversionResult({required this.code, required this.message});

  final int code;
  final String message;
  bool get succeeded => code == 0;
  bool get cancelled => code == 11;
}

class NativeAudioConverter {
  NativeAudioConverter._();

  static DynamicLibrary? _library;
  static _DartProgress? _progress;
  static _DartCancel? _cancel;

  static DynamicLibrary _load() {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'The high-performance FIR engine currently requires Windows.',
      );
    }
    return DynamicLibrary.open(
      path.join(
        File(Platform.resolvedExecutable).parent.path,
        'gac_audio_engine.dll',
      ),
    );
  }

  static DynamicLibrary get _mainLibrary => _library ??= _load();

  static double get progress {
    _progress ??= _mainLibrary.lookupFunction<_NativeProgress, _DartProgress>(
      'gac_get_progress',
    );
    return _progress!().clamp(0.0, 1.0);
  }

  static void cancel() {
    _cancel ??= _mainLibrary.lookupFunction<_NativeCancel, _DartCancel>(
      'gac_request_cancel',
    );
    _cancel!();
  }

  static Future<NativeConversionResult> convert({
    required String inputPath,
    required String outputPath,
    required FirDesign design,
    required FirQuality quality,
    required double headroomDb,
    required OutputBitDepth outputBitDepth,
    required bool noiseShaping,
    required bool tpdfDither,
  }) async {
    final result = await Isolate.run<Map<String, Object>>(() {
      final library = _load();
      final convert = library.lookupFunction<_NativeConvert, _DartConvert>(
        'gac_convert_wav',
      );
      final copyError = library
          .lookupFunction<_NativeCopyError, _DartCopyError>(
            'gac_copy_last_error',
          );
      final input = inputPath.toNativeUtf16();
      final output = outputPath.toNativeUtf16();
      try {
        final code = convert(
          input,
          output,
          design.index,
          quality.index,
          headroomDb,
          outputBitDepth.bits,
          noiseShaping ? 1 : 0,
          tpdfDither ? 1 : 0,
        );
        final required = copyError(nullptr, 0).clamp(1, 4096);
        final error = calloc<Uint16>(required).cast<Utf16>();
        try {
          copyError(error, required);
          return <String, Object>{
            'code': code,
            'message': error.toDartString(),
          };
        } finally {
          calloc.free(error);
        }
      } finally {
        calloc.free(input);
        calloc.free(output);
      }
    });
    return NativeConversionResult(
      code: result['code']! as int,
      message: result['message']! as String,
    );
  }
}
