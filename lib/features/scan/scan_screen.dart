
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import '../../data/services/prediction_service.dart';
import '../../data/models/detection.dart';
import '../../widgets/bounding_box_painter.dart';

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
  int _inferenceMs = 0;
  
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
        _inferenceMs = result.inferenceOnlyTime;
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

    _predictionService.processFrame(image, rotation);
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

  Future<void> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_cameraController!.value.isTakingPicture) return;

    try {
      // Pause stream to capture
      await _cameraController!.stopImageStream();
      
      final XFile file = await _cameraController!.takePicture();
      
      if (mounted) {
        // Navigate to Detail Screen
        Navigator.pushNamed(
          context, 
          '/analysis-detail',
          arguments: {
             'imageUri': file.path, 
             'source': 'camera', 
             'detections': _detections // Pass current detections if we want to show them immediately? 
                                          // Or let detail screen re-run on high-res image?
                                          // Better to let Detail re-run on the high-res image for accuracy.
             // Actually, DetailScreen needs to run prediction on the static image.
          }
        ).then((_) {
          // Restart stream when coming back
          if (mounted && _cameraController != null) {
            _cameraController!.startImageStream(_onFrame);
          }
        });
      }
    } catch (e) {
      debugPrint('Capture Error: $e');
      // Restart if failed and validated
      try {
         _cameraController?.startImageStream(_onFrame);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _predictionService.dispose();
    super.dispose();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle camera resource release/acquire on background/foreground
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
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
                      
                      // FPS / Stats
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_inferenceMs > 0 ? (1000/_inferenceMs).toStringAsFixed(1) : "0"} FPS (${_inferenceMs}ms)',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
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
                
                // Bottom Controls
                Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: Row(
                     mainAxisAlignment: MainAxisAlignment.center,
                     children: [
                        // Capture Button
                        GestureDetector(
                          onTap: _takePicture,
                          child: Container(
                             width: 80, height: 80,
                             decoration: BoxDecoration(
                               shape: BoxShape.circle,
                               border: Border.all(color: Colors.white, width: 4),
                               color: Colors.white24
                             ),
                             child: Center(
                               child: Container(
                                 width: 60, height: 60,
                                 decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                 ),
                               ),
                             ),
                          ),
                        ) 
                     ],
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
