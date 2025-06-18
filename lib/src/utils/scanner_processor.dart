import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ml_card_scanner/src/model/card_info.dart';
import 'package:ml_card_scanner/src/parser/parser_algorithm.dart';
import 'package:ml_card_scanner/src/utils/camera_image_util.dart';
import 'package:ml_card_scanner/src/utils/image_processor.dart';
import 'package:ml_card_scanner/src/utils/stream_debouncer.dart';

class ScannerProcessor {
  static const _kDebugOutputCooldownMillis = 5000;
  final bool _usePreprocessingFilters;
  final bool _debugOutputFilteredImage;
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  StreamController<Uint8List>? _debugImageStreamController;

  ScannerProcessor({
    bool usePreprocessingFilters = false,
    bool debugOutputFilteredImage = false,
  })  : _usePreprocessingFilters = usePreprocessingFilters,
        _debugOutputFilteredImage = debugOutputFilteredImage {
    if (_debugOutputFilteredImage) {
      _debugImageStreamController = StreamController<Uint8List>.broadcast();
    }
  }

  Stream<Uint8List>? get imageStream =>
      _debugImageStreamController?.stream.transform(
        debounceTransformer(
          const Duration(milliseconds: _kDebugOutputCooldownMillis),
        ),
      );

  /// google_mlkit_commons 가이드라인에 따른 최적화된 이미지 처리
  Future<CardInfo?> computeImage(
    ParserAlgorithm parseAlgorithm,
    CameraImage image,
    InputImageRotation rotation,
  ) async {
    try {
      final inputImage = await _createInputImage(image, rotation);
      if (inputImage == null) return null;

      final recognizedText = await _recognizer.processImage(inputImage);

      if (kDebugMode) {
        _debugPrintRecognizedText(recognizedText);
      }

      final parsedCard = await parseAlgorithm.parse(recognizedText);
      return parsedCard;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error processing image: $e');
      }
      return null;
    }
  }

  /// google_mlkit_commons 가이드라인에 따른 InputImage 생성
  Future<InputImage?> _createInputImage(
    CameraImage image,
    InputImageRotation rotation,
  ) async {
    // 이미지 포맷 검증 (google_mlkit_commons 가이드라인 따름)
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      if (kDebugMode) {
        debugPrint('Unsupported image format: ${image.format.raw}');
      }
      return null;
    }

    if (kDebugMode) {
      debugPrint(
          '📸 Camera image format detected: $format (raw: ${image.format.raw})');
      debugPrint(
          '📏 Image size: ${image.width}x${image.height}, planes: ${image.planes.length}');
    }

    // GitHub 이슈 #145961 대응 로그
    if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
      if (format == InputImageFormat.yuv420 ||
          format == InputImageFormat.yuv_420_888) {
        debugPrint(
            'Android: Detected YUV420_888 format (${image.format.raw}), converting to nv21 for ML Kit');
      } else if (format == InputImageFormat.nv21) {
        debugPrint(
            'Android: Using nv21 format (${image.format.raw}) as expected');
      }
    }

    // 평면 수 기반 포맷 검증 (더 확실한 방법)
    if (kDebugMode) {
      debugPrint('🔍 Format validation:');
      debugPrint('   Detected format: $format (raw: ${image.format.raw})');
      debugPrint('   Planes count: ${image.planes.length}');
      debugPrint('   Platform: ${defaultTargetPlatform}');
    }

    if (image.planes.length == 3) {
      // 3개 평면 = YUV420 계열 포맷
      if (kDebugMode) {
        debugPrint('✅ 3-plane format detected - treating as YUV420_888');
      }

      // Android에서 3평면 포맷은 YUV420_888으로 처리
      if (defaultTargetPlatform == TargetPlatform.android) {
        if (kDebugMode) {
          debugPrint('🔄 Will convert YUV420_888 to NV21 for ML Kit');
        }
      } else {
        if (kDebugMode) {
          debugPrint('❌ YUV420_888 format not supported on iOS');
        }
        return null;
      }
    } else if (image.planes.length == 1) {
      // 1개 평면 = NV21 또는 BGRA8888
      if (kDebugMode) {
        debugPrint('✅ Single-plane format detected: $format');
      }

      // 플랫폼별 단일 평면 포맷 검증
      if (defaultTargetPlatform == TargetPlatform.android &&
          format != InputImageFormat.nv21) {
        if (kDebugMode) {
          debugPrint('❌ Android requires NV21 format, got: $format');
        }
        return null;
      } else if (defaultTargetPlatform == TargetPlatform.iOS &&
          format != InputImageFormat.bgra8888) {
        if (kDebugMode) {
          debugPrint('❌ iOS requires BGRA8888 format, got: $format');
        }
        return null;
      }
    } else {
      // 지원하지 않는 평면 수
      if (kDebugMode) {
        debugPrint('❌ Unsupported plane count: ${image.planes.length}');
      }
      return null;
    }

    if (!_usePreprocessingFilters) {
      // 표준 방식: 직접 바이트 사용 (메모리 효율적)
      return _createStandardInputImage(image, format, rotation);
    } else {
      // 전처리 필터 사용 (Isolate에서 처리) - 단일 평면만 지원
      if (image.planes.length != 1) {
        if (kDebugMode) {
          debugPrint(
              '❌ Preprocessing filters only support single-plane formats');
        }
        return null;
      }
      final plane = image.planes.first;
      return _createPreprocessedInputImage(image, plane, format, rotation);
    }
  }

  /// 표준 InputImage 생성 (메모리 효율적)
  InputImage _createStandardInputImage(
    CameraImage image,
    InputImageFormat format,
    InputImageRotation rotation,
  ) {
    // GitHub 이슈 #145961 대응: 3개 평면 = YUV420_888을 실제 NV21 데이터로 변환
    if (defaultTargetPlatform == TargetPlatform.android &&
        image.planes.length == 3) {
      try {
        if (kDebugMode) {
          debugPrint(
              '🔄 Converting 3-plane YUV420_888 to NV21 for ML Kit processing');
        }

        final nv21Data = CameraImageUtil.convertYUV420ToNV21(image);

        return InputImage.fromBytes(
          bytes: nv21Data,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: image.width,
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('❌ Failed to convert YUV420_888 to NV21: $e');
        }
        // 변환 실패 시 기본 처리로 fallback
      }
    }

    // 기본 처리 (단일 평면: NV21 또는 BGRA8888) 또는 변환 실패 시 fallback
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// 전처리가 포함된 InputImage 생성
  Future<InputImage> _createPreprocessedInputImage(
    CameraImage image,
    Plane plane,
    InputImageFormat format,
    InputImageRotation rotation,
  ) async {
    final rawFormat = image.format.raw;
    final rawRotation = rotation.rawValue;
    final bytes = plane.bytes;
    final width = image.width;
    final height = image.height;
    final bytesPerRow = plane.bytesPerRow;

    ReceivePort? receivePort;
    if (_debugOutputFilteredImage) {
      receivePort = ReceivePort();
      receivePort.listen(
        (message) {
          if (message is Uint8List) {
            if (_debugImageStreamController != null &&
                !_debugImageStreamController!.isClosed) {
              _debugImageStreamController?.add(message);
            }
          }
        },
      );
    }

    final inputImage = await createInputImageInIsolate(
      rawBytes: bytes,
      width: width,
      height: height,
      rawRotation: rawRotation,
      rawFormat: rawFormat,
      bytesPerRow: bytesPerRow,
      debugSendPort: receivePort?.sendPort,
    );

    receivePort?.close();
    return inputImage;
  }

  /// 디버그용 인식된 텍스트 출력
  void _debugPrintRecognizedText(RecognizedText recognizedText) {
    debugPrint('\n=== Recognized Text ===');
    debugPrint('Full Text: ${recognizedText.text}');
    debugPrint('Blocks (${recognizedText.blocks.length}):');
    for (int i = 0; i < recognizedText.blocks.length; i++) {
      final block = recognizedText.blocks[i];
      debugPrint('  Block $i: "${block.text.trim()}"');
      debugPrint('    Bounds: ${block.boundingBox}');
      if (block.recognizedLanguages.isNotEmpty) {
        debugPrint('    Languages: ${block.recognizedLanguages.join(", ")}');
      }
    }
    debugPrint('======================\n');
  }

  void dispose() {
    if (_debugImageStreamController != null &&
        !_debugImageStreamController!.isClosed) {
      _debugImageStreamController?.close();
    }
    unawaited(_recognizer.close());
  }
}
