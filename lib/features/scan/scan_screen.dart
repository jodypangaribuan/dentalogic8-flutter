
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import '../../data/services/prediction_service.dart';
import '../../data/models/detection.dart';
import '../../widgets/bounding_box_painter.dart';
import '../../widgets/premium_widgets.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isDetecting = false;
  final PredictionService _predictionService = PredictionService();
  
  List<DetectionResult> _detections = [];
  
  bool _flashOn = false;
  int _cameraIndex = 0; // 0 for back, 1 for front usually

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeAll();
  }

  Future<void> _initializeAll() async {
    await _predictionService.initialize();
    
    // Listen for results
    _predictionService.results.listen((result) {
      if (!mounted) return;
      setState(() {
        _detections = result.detections;
        _isDetecting = false;
      });
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        // Find back camera first
        final backCameraIdx = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
        if (backCameraIdx != -1) _cameraIndex = backCameraIdx;
        
        await _initializeCamera();
      }
    } catch (e) {
      debugPrint('Camera Error: $e');
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
    }

    final camera = _cameras[_cameraIndex];
    _cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_onFrame);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Camera Init Error: $e');
    }
  }

  void _onFrame(CameraImage image) {
    if (_isDetecting) return;
    _isDetecting = true;
    
    // Calculate rotation
    // This part logic is tricky to get right across all devices, sticking to simple logic for now
    // derived from main.dart
    final deviceOrientation = _cameraController!.value.deviceOrientation;
    int rotation = 90;
    if (deviceOrientation == DeviceOrientation.landscapeLeft) rotation = 0;
    if (deviceOrientation == DeviceOrientation.landscapeRight) rotation = 180;
    if (deviceOrientation == DeviceOrientation.portraitDown) rotation = 270;
    
    // Adjust for front camera mirroring if needed?
    // TFLite usually needs rotation relative to sensor.
    // For now passing rotation assuming backend handles it as per main.dart logic.
    final bool isFront = _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

    _predictionService.processFrame(image, rotation, isFrontCamera: isFront);
  }

  Future<void> _toggleCamera() async {
    if (_cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initializeCamera();
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null) return;
    try {
      _flashOn = !_flashOn;
      await _cameraController!.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
      setState(() {});
    } catch (e) {
      debugPrint('Flash Error: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _predictionService.dispose();
    super.dispose();
  }
  
  Future<void> _stopCamera() async {
    if (_cameraController != null) {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController!.dispose();
      _cameraController = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle camera resource release/acquire on background/foreground
    // if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    
    if (state == AppLifecycleState.inactive) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: PremiumLoadingSpinner(color: Colors.white, message: 'Menyiapkan kamera...')));
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera Feed
          Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(_cameraController!)),
          ),
          
          // Bounding Boxes
          Transform.scale(
            scale: scale,
            child: Center(
              child: AspectRatio(
                aspectRatio: 1 / _cameraController!.value.aspectRatio,
                child: CustomPaint(
                  painter: BoundingBoxPainter(detections: _detections),
                ),
              ),
            ),
          ),
          
          // Overlays
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Top Bar
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                        style: IconButton.styleFrom(
                           backgroundColor: Colors.black45,
                        ),
                      ),
                      
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(_flashOn ? Icons.flash_on : Icons.flash_off, color: _flashOn ? Colors.amber : Colors.white),
                            onPressed: _toggleFlash,
                            style: IconButton.styleFrom(backgroundColor: Colors.black45),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.cameraswitch, color: Colors.white),
                            onPressed: _toggleCamera,
                            style: IconButton.styleFrom(backgroundColor: Colors.black45),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
