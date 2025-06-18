import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// google_mlkit_commons 가이드라인에 따른 카메라 이미지 유틸리티
class CameraImageUtil {
  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// google_mlkit_commons 가이드라인에 따른 이미지 회전 계산
  ///
  /// Android와 iOS에서 다르게 처리되는 회전 로직을 정확히 구현
  static InputImageRotation? getImageRotation(
    int sensorOrientation,
    DeviceOrientation deviceOrientation,
    CameraLensDirection lensDirection,
  ) {
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      // iOS: sensorOrientation 값을 직접 사용
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      // Android: 디바이스 방향과 센서 방향을 조합하여 계산
      var rotationCompensation = _orientations[deviceOrientation];
      if (rotationCompensation == null) {
        if (kDebugMode) {
          debugPrint('Unknown device orientation: $deviceOrientation');
        }
        return null;
      }

      if (lensDirection == CameraLensDirection.front) {
        // 전면 카메라: 센서 방향 + 디바이스 방향
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        // 후면 카메라: 센서 방향 - 디바이스 방향
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }

      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }

    if (rotation == null && kDebugMode) {
      debugPrint(
          'Failed to determine rotation for platform: ${Platform.operatingSystem}');
    }

    return rotation;
  }

  /// InputImage 생성을 위한 이미지 포맷 검증
  static bool isImageFormatSupported(int rawFormat) {
    final format = InputImageFormatValue.fromRawValue(rawFormat);
    if (format == null) return false;

    // google_mlkit_commons 가이드라인에 따른 플랫폼별 지원 포맷
    if (Platform.isAndroid) {
      // GitHub 이슈 #145961: camera_android_camerax에서 nv21 설정해도 yuv_420_888 반환되는 버그 대응
      return format == InputImageFormat.nv21 ||
          format == InputImageFormat.yuv420 ||
          format == InputImageFormat.yuv_420_888;
    } else if (Platform.isIOS) {
      return format == InputImageFormat.bgra8888;
    }

    return false;
  }

  /// Android에서 yuv_420_888을 nv21로 변환 필요 여부 확인
  static bool needsFormatConversion(int rawFormat) {
    if (!Platform.isAndroid) return false;
    final format = InputImageFormatValue.fromRawValue(rawFormat);
    return format == InputImageFormat.yuv420 ||
        format == InputImageFormat.yuv_420_888;
  }

  /// Android에서 사용하는 플랫폼 체크
  static bool isAndroid() => Platform.isAndroid;

  /// YUV420_888 포맷을 NV21 포맷으로 변환
  /// GitHub 이슈 #145961 대응을 위한 실제 데이터 변환
  static Uint8List convertYUV420ToNV21(CameraImage image) {
    final width = image.width;
    final height = image.height;

    // YUV420_888 포맷 검증
    if (image.planes.length != 3) {
      throw ArgumentError(
          'YUV420_888 format requires exactly 3 planes, got ${image.planes.length}');
    }

    // Planes from CameraImage
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    // Buffers from Y, U, and V planes
    final yBuffer = yPlane.bytes;
    final uBuffer = uPlane.bytes;
    final vBuffer = vPlane.bytes;

    // Total number of pixels in NV21 format
    final numPixels = width * height + (width * height ~/ 2);
    final nv21 = Uint8List(numPixels);

    // Y (Luma) plane metadata
    int idY = 0;
    int idUV = width * height; // Start UV after Y plane
    final uvWidth = width ~/ 2;
    final uvHeight = height ~/ 2;

    // Strides and pixel strides for Y and UV planes
    final yRowStride = yPlane.bytesPerRow;
    final yPixelStride = yPlane.bytesPerPixel ?? 1;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 2;

    if (kDebugMode) {
      debugPrint(
          '🔄 Converting YUV420_888 (format code: ${image.format.raw}) to NV21:');
      debugPrint('   Image size: ${width}x$height');
      debugPrint(
          '   Y plane: stride=$yRowStride, pixelStride=$yPixelStride, bytes=${yBuffer.length}');
      debugPrint(
          '   U plane: stride=$uvRowStride, pixelStride=$uvPixelStride, bytes=${uBuffer.length}');
      debugPrint(
          '   V plane: stride=${vPlane.bytesPerRow}, pixelStride=${vPlane.bytesPerPixel ?? 2}, bytes=${vBuffer.length}');
      debugPrint('   Target NV21 size: $numPixels bytes');
    }

    // Copy Y (Luma) channel
    for (int y = 0; y < height; ++y) {
      final yOffset = y * yRowStride;
      for (int x = 0; x < width; ++x) {
        nv21[idY++] = yBuffer[yOffset + x * yPixelStride];
      }
    }

    // Copy UV (Chroma) channels in NV21 format (YYYYVU interleaved)
    for (int y = 0; y < uvHeight; ++y) {
      final uvOffset = y * uvRowStride;
      for (int x = 0; x < uvWidth; ++x) {
        final bufferIndex = uvOffset + (x * uvPixelStride);
        nv21[idUV++] = vBuffer[bufferIndex]; // V channel
        nv21[idUV++] = uBuffer[bufferIndex]; // U channel
      }
    }

    if (kDebugMode) {
      debugPrint('✅ YUV420_888 to NV21 conversion completed successfully');
    }

    return nv21;
  }

  /// 카메라 이미지에서 InputImage 생성 (실제 데이터 변환 포함)
  static InputImage? inputImageFromCameraImage(
    CameraImage image,
    int sensorOrientation,
    DeviceOrientation deviceOrientation,
    CameraLensDirection lensDirection,
  ) {
    // 회전 계산
    final rotation = getImageRotation(
      sensorOrientation,
      deviceOrientation,
      lensDirection,
    );
    if (rotation == null) return null;

    // 이미지 포맷 검증
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null || !isImageFormatSupported(image.format.raw)) {
      return null;
    }

    // GitHub 이슈 #145961 대응: YUV420_888을 실제 NV21 데이터로 변환
    if (isAndroid() &&
        (format == InputImageFormat.yuv420 ||
            format == InputImageFormat.yuv_420_888)) {
      try {
        final nv21Data = convertYUV420ToNV21(image);

        return InputImage.fromBytes(
          bytes: nv21Data,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: image.width, // NV21 포맷의 bytes per row
          ),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('❌ Failed to convert YUV420_888 to NV21: $e');
        }
        return null;
      }
    }

    // 기본 처리 (NV21 또는 BGRA8888)
    if (image.planes.length != 1) return null;
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

  const CameraImageUtil._();
}
