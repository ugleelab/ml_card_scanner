import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ml_card_scanner/ml_card_scanner.dart';
import 'package:ml_card_scanner/src/model/typedefs.dart';
import 'package:ml_card_scanner/src/parser/default_parser_algorithm.dart';
import 'package:ml_card_scanner/src/parser/parser_algorithm.dart';
import 'package:ml_card_scanner/src/utils/camera_image_util.dart';
import 'package:ml_card_scanner/src/utils/logger.dart';
import 'package:ml_card_scanner/src/utils/resolution_preset_ext.dart';
import 'package:ml_card_scanner/src/utils/scanner_processor.dart';
import 'package:ml_card_scanner/src/widget/camera_overlay_widget.dart';
import 'package:ml_card_scanner/src/widget/camera_widget.dart';
import 'package:ml_card_scanner/src/widget/text_overlay_widget.dart';
import 'package:permission_handler/permission_handler.dart';

class ScannerWidget extends StatefulWidget {
  final CardOrientation overlayOrientation;
  final OverlayBuilder? overlayBuilder;
  final int scannerDelay;
  final bool oneShotScanning;
  final CameraResolution cameraResolution;
  final ScannerWidgetController? controller;
  final CameraPreviewBuilder? cameraPreviewBuilder;
  final OverlayTextBuilder? overlayTextBuilder;
  final int cardScanTries;
  final bool usePreprocessingFilters;

  const ScannerWidget({
    this.overlayBuilder,
    this.controller,
    this.scannerDelay = 400,
    this.cardScanTries = 5,
    this.oneShotScanning = true,
    this.overlayOrientation = CardOrientation.portrait,
    this.cameraResolution = CameraResolution.high,
    this.cameraPreviewBuilder,
    this.overlayTextBuilder,
    this.usePreprocessingFilters = false,
    super.key,
  });

  @override
  State<ScannerWidget> createState() => _ScannerWidgetState();
}

class _ScannerWidgetState extends State<ScannerWidget>
    with WidgetsBindingObserver {
  static const _kDebugOutputFilteredImage = false;
  final ValueNotifier<CameraController?> _isInitialized = ValueNotifier(null);
  late ScannerProcessor _processor;
  late CameraDescription _camera;
  late ScannerWidgetController _scannerController;
  late final ParserAlgorithm _algorithm =
      DefaultParserAlgorithm(widget.cardScanTries);
  CameraController? _cameraController;
  bool _isBusy = false;
  int _lastFrameDecode = 0;

  @override
  void initState() {
    super.initState();
    _processor = ScannerProcessor(
      usePreprocessingFilters: widget.usePreprocessingFilters,
      debugOutputFilteredImage: _kDebugOutputFilteredImage,
    );
    WidgetsBinding.instance.addObserver(this);
    _scannerController = widget.controller ?? ScannerWidgetController();
    _scannerController.addListener(_scanParamsListener);
    _initialize();

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitDown,
      DeviceOrientation.portraitUp,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final debugImageSize = min(screenSize.width, screenSize.height);
    return Stack(
      children: <Widget>[
        ValueListenableBuilder<CameraController?>(
          valueListenable: _isInitialized,
          builder: (context, cc, _) {
            if (cc == null) return const SizedBox.shrink();
            _cameraController = cc;
            return CameraWidget(
              cameraController: cc,
              cameraPreviewBuilder: widget.cameraPreviewBuilder,
            );
          },
        ),
        widget.overlayBuilder?.call(context) ??
            CameraOverlayWidget(
              cardOrientation: widget.overlayOrientation,
              overlayBorderRadius: 25,
              overlayColorFilter: Colors.white30,
            ),
        widget.overlayTextBuilder?.call(context) ??
            Positioned(
              left: 0,
              right: 0,
              bottom: (MediaQuery.sizeOf(context).height / 5),
              child: const TextOverlayWidget(),
            ),
        if (_kDebugOutputFilteredImage)
          Align(
            alignment: Alignment.bottomRight,
            child: SizedBox(
              width: debugImageSize,
              height: debugImageSize,
              child: StreamBuilder(
                stream: _processor.imageStream,
                builder: (_, snapshot) {
                  if (snapshot.data != null) {
                    return Image.memory(snapshot.data!, fit: BoxFit.scaleDown);
                  }
                  return const Placeholder();
                },
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerController.removeListener(_scanParamsListener);
    _cameraController?.dispose();
    _processor.dispose();
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    final isCameraInitialized = _cameraController?.value.isInitialized ?? false;

    if (state == AppLifecycleState.inactive) {
      final isStreaming = _cameraController?.value.isStreamingImages ?? false;
      _isInitialized.value = null;
      if (isStreaming) {
        _cameraController?.stopImageStream();
      }
      _cameraController?.dispose();
      _cameraController = null;
    } else if (state == AppLifecycleState.resumed) {
      if (isCameraInitialized) {
        return;
      }
      _initializeCamera();
    }
  }

  void _initialize() async {
    try {
      await _initializeCamera();
    } catch (e) {
      _handleError(ScannerException(e.toString()));
    }
  }

  Future<CameraController?> _initializeCamera() async {
    var status = await Permission.camera.request();
    if (!status.isGranted) {
      _handleError(const ScannerPermissionIsNotGrantedException());
      return null;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      _handleError(const ScannerNoCamerasAvailableException());
      return null;
    }

    final backCamera = cameras
        .where((cam) => cam.lensDirection == CameraLensDirection.back)
        .firstOrNull;

    if (backCamera == null) {
      _handleError(const ScannerNoBackCameraAvailableException());
      return null;
    }

    _camera = backCamera;

    // google_mlkit_commons 가이드라인에 따른 카메라 컨트롤러 설정
    final cameraController = CameraController(
      _camera,
      widget.cameraResolution.convertToResolutionPreset(),
      enableAudio: false,
      // 플랫폼별 최적화된 이미지 포맷 설정
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 // Android: nv21 (YUV420)
          : ImageFormatGroup.bgra8888, // iOS: bgra8888 (RGBA)
    );

    try {
      await cameraController.initialize();

      if (!cameraController.value.isInitialized) {
        cameraController.dispose();
        _handleError(const ScannerException('Camera initialization failed'));
        return null;
      }

      if (kDebugMode) {
        debugPrint('✅ Camera initialized successfully');
        debugPrint('📱 Platform: ${Platform.operatingSystem}');
        debugPrint(
            '🔧 Requested format: ${Platform.isAndroid ? "nv21" : "bgra8888"}');
        debugPrint(
            'ℹ️  Note: Due to GitHub issue #145961, Android may use yuv_420_888 instead of nv21');
      }

      final isStreaming = _cameraController?.value.isStreamingImages ?? false;
      if (_scannerController.scanningEnabled && !isStreaming) {
        await cameraController.startImageStream(_onFrame);
      }

      _isInitialized.value = cameraController;
      return cameraController;
    } catch (e) {
      cameraController.dispose();
      _handleError(ScannerException('Camera initialization error: $e'));
      return null;
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    final cc = _cameraController;
    if (cc == null || !cc.value.isInitialized) return;
    if (!_scannerController.scanningEnabled) return;

    final currentTime = DateTime.now().millisecondsSinceEpoch;
    if ((currentTime - _lastFrameDecode) < widget.scannerDelay) {
      return;
    }
    _lastFrameDecode = currentTime;

    await _handleInputImage(image, cc);
  }

  Future<void> _handleInputImage(
    CameraImage image,
    CameraController cc,
  ) async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      if (!_isImageValid(image)) {
        return;
      }

      final sensorOrientation = _camera.sensorOrientation;
      final rotation = CameraImageUtil.getImageRotation(
        sensorOrientation,
        cc.value.deviceOrientation,
        _camera.lensDirection,
      );

      if (rotation == null) {
        if (kDebugMode) {
          debugPrint('Unable to determine image rotation');
        }
        return;
      }

      final cardInfo =
          await _processor.computeImage(_algorithm, image, rotation);

      if (cardInfo != null) {
        if (widget.oneShotScanning) {
          _scannerController.disableScanning();
        }
        _handleData(cardInfo);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error handling input image: $e');
      }
    } finally {
      _isBusy = false;
    }
  }

  /// 이미지 유효성 검증 (google_mlkit_commons 가이드라인)
  bool _isImageValid(CameraImage image) {
    // 기본 유효성 검사
    if (image.planes.isEmpty) {
      if (kDebugMode) {
        debugPrint('Invalid image: no planes');
      }
      return false;
    }

    if (kDebugMode) {
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      debugPrint(
          '🔍 Widget validation - Format: $format (raw: ${image.format.raw}), Planes: ${image.planes.length}');
    }

    // 평면 수 기반 검증 (scanner_processor.dart와 동일한 로직)
    if (image.planes.length == 3) {
      // 3개 평면 = YUV420_888 계열 포맷
      if (Platform.isAndroid) {
        if (kDebugMode) {
          debugPrint(
              '✅ Widget: 3-plane YUV420_888 format detected, will convert to NV21');
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('❌ Widget: YUV420_888 format not supported on iOS');
        }
        return false;
      }
    } else if (image.planes.length == 1) {
      // 1개 평면 = NV21 또는 BGRA8888
      final format = InputImageFormatValue.fromRawValue(image.format.raw);

      if (Platform.isAndroid && format == InputImageFormat.nv21) {
        if (kDebugMode) {
          debugPrint('✅ Widget: NV21 format validated');
        }
        return true;
      } else if (Platform.isIOS && format == InputImageFormat.bgra8888) {
        if (kDebugMode) {
          debugPrint('✅ Widget: BGRA8888 format validated');
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint(
              '❌ Widget: Unsupported single-plane format $format on ${Platform.operatingSystem}');
        }
        return false;
      }
    } else {
      // 지원하지 않는 평면 수
      if (kDebugMode) {
        debugPrint('❌ Widget: Unsupported plane count: ${image.planes.length}');
      }
      return false;
    }
  }

  void _scanParamsListener() {
    final isStreaming = _cameraController?.value.isStreamingImages ?? false;
    if (_scannerController.scanningEnabled) {
      if (!isStreaming) {
        _cameraController?.startImageStream(_onFrame);
      }
    } else {
      if (isStreaming) {
        _cameraController?.stopImageStream();
      }
    }
    if (_scannerController.cameraPreviewEnabled) {
      _cameraController?.resumePreview();
    } else {
      _cameraController?.pausePreview();
    }

    if (_scannerController.cameraTorchEnabled) {
      _cameraController?.setFlashMode(FlashMode.torch);
    } else {
      _cameraController?.setFlashMode(FlashMode.off);
    }
  }

  void _handleData(CardInfo cardInfo) {
    Logger.log('Detect Card Details', cardInfo.toString());
    final cardScannedCallback = _scannerController.onCardScanned;
    cardScannedCallback?.call(cardInfo);
  }

  void _handleError(ScannerException exception) {
    final errorCallback = _scannerController.onError;
    errorCallback?.call(exception);
  }
}
