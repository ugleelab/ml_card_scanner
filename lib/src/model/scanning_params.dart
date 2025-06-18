import 'package:flutter/material.dart';
import 'package:ml_card_scanner/src/model/card_info.dart';
import 'package:ml_card_scanner/src/model/exceptions/scanner_exception.dart';

class ScanningParams {
  final bool scanningEnabled;
  final bool cameraPreviewEnabled;
  final bool cameraTorchEnabled;
  final ValueChanged<CardInfo>? onCardScanned;
  final ValueChanged<ScannerException>? onError;

  const ScanningParams({
    required this.scanningEnabled,
    required this.cameraPreviewEnabled,
    required this.cameraTorchEnabled,
    required this.onCardScanned,
    required this.onError,
  });

  factory ScanningParams.defaultParams() => const ScanningParams(
        scanningEnabled: true,
        cameraPreviewEnabled: true,
        cameraTorchEnabled: false,
        onCardScanned: null,
        onError: null,
      );

  ScanningParams copyWith({
    bool? scanningEnabled,
    bool? cameraPreviewEnabled,
    bool? cameraTorchEnabled,
    ValueChanged<CardInfo?>? onCardScanned,
    ValueChanged<ScannerException>? onError,
  }) =>
      ScanningParams(
        scanningEnabled: scanningEnabled ?? this.scanningEnabled,
        onCardScanned: onCardScanned ?? this.onCardScanned,
        cameraTorchEnabled: cameraTorchEnabled ?? this.cameraTorchEnabled,
        cameraPreviewEnabled: cameraPreviewEnabled ?? this.cameraPreviewEnabled,
        onError: onError ?? this.onError,
      );
}
