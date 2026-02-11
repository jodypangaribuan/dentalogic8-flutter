import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ─── Model Constants ──────────────────────────────────────────────
const int kInputSize = 640;
const int kNumClasses = 7;
const int kNumAnchors = 8400;
const double kConfThreshold = 0.45;
const double kIouThreshold = 0.45;

const List<String> classNames = ['D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6'];
const List<Color> classColors = [
  Color(0xFF4CAF50), Color(0xFF8BC34A), Color(0xFFFFEB3B),
  Color(0xFFFF9800), Color(0xFFFF5722), Color(0xFFF44336), Color(0xFF9C27B0),
];

// ─── Detection Result ─────────────────────────────────────────────
class DetectionResult {
  final double x, y, w, h;
  final int classId;
  final double confidence;
  DetectionResult(this.x, this.y, this.w, this.h, this.classId, this.confidence);
  Color get color => classColors[classId];
  String get className => classNames[classId];
}

// ─── Processing Result DTO ────────────────────────────────────────
class ProcessingResult {
  final int id;
  final Uint8List data; // Float32 input bytes
  ProcessingResult(this.id, this.data);
}

// ─── Isolate DTOs ─────────────────────────────────────────────────
class InitRequest {
  final SendPort sendPort;
  final Uint8List modelBytes;
  InitRequest(this.sendPort, this.modelBytes);
}

class FrameRequest {
  final int id;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width, height;
  final int yRowStride, uvRowStride, uvPixelStride;
  final int rotation; // 0, 90, 180, 270

  FrameRequest(this.id, this.yPlane, this.uPlane, this.vPlane,
      this.width, this.height, this.yRowStride, this.uvRowStride, this.uvPixelStride, this.rotation);
}

// ─── Isolate Entry Point (Full Pipeline) ──────────────────────────
void isolateEntry(InitRequest initReq) async {
  final receivePort = ReceivePort();
  initReq.sendPort.send(receivePort.sendPort);

  // Initialize TFLite
  Interpreter? interpreter;
  Tensor? inputTensor;
  Tensor? outputTensor;
  final outputBuffer = Float32List(1 * 11 * 8400);

  try {
    final options = InterpreterOptions()..threads = 4;
    if (Platform.isAndroid) {
      try {
        // Attempt GPU with safe options
        options.addDelegate(GpuDelegateV2(
          options: GpuDelegateOptionsV2(
            isPrecisionLossAllowed: true, // Allow FP16 for speed
            // inferencePreference: TfLiteGpuInferenceUsage.fastSingleAnswer, // Not available in Dart definition
          )
        ));
      } catch (e) {
        print("Isolate GPU Error: $e");
      }
    }
    interpreter = Interpreter.fromBuffer(initReq.modelBytes, options: options);
    interpreter.allocateTensors();
    inputTensor = interpreter.getInputTensors().first;
    outputTensor = interpreter.getOutputTensors().first;
  } catch (e) {
    print("Isolate Init Error: $e");
  }

  await for (final message in receivePort) {
    if (message is FrameRequest) {
       if (interpreter == null) continue;
       
       final sw = Stopwatch()..start();
       try {
         // 1. Preprocess
         final inputBytes = _preprocess(message);
         
         // 2. Inference
         inputTensor!.setTo(inputBytes);
         interpreter.invoke();
         outputTensor!.copyTo(outputBuffer.buffer.asUint8List());
         
         // 3. Postprocess
         final detections = postProcess(outputBuffer);
         sw.stop();
         
         // Send Results back
         initReq.sendPort.send(InferenceResult(message.id, detections, sw.elapsedMilliseconds));
       } catch (e) {
         print("Pipeline Error: $e");
       }
    }
  }
}

// Optimized Preprocessing (Integer Math + Rotation)
Uint8List _preprocess(FrameRequest req) {
  // Returns bytes for Float32 input tensor
  final totalElements = kInputSize * kInputSize * 3;
  final float32Data = Float32List(totalElements);
  
  final int inW = req.width;
  final int inH = req.height;
  
  for (int outY = 0; outY < kInputSize; outY++) {
    for (int outX = 0; outX < kInputSize; outX++) {
      int srcX, srcY;

      // Map output (outX, outY) to input (srcX, srcY) based on rotation
      switch (req.rotation) {
        case 90: // Portrait Up (Standard)
          srcX = (outY * inW) ~/ kInputSize;
          srcY = ((kInputSize - 1 - outX) * inH) ~/ kInputSize;
          break;
        case 270: // Portrait Down
        case -90:
          srcX = ((kInputSize - 1 - outY) * inW) ~/ kInputSize;
          srcY = (outX * inH) ~/ kInputSize;
          break;
        case 180: // Landscape Right
          srcX = ((kInputSize - 1 - outX) * inW) ~/ kInputSize;
          srcY = ((kInputSize - 1 - outY) * inH) ~/ kInputSize;
          break;
        case 0: // Landscape Left
        default:
          srcX = (outX * inW) ~/ kInputSize;
          srcY = (outY * inH) ~/ kInputSize;
          break;
      }

      // Safe clamp
      if (srcX < 0) srcX = 0; else if (srcX >= inW) srcX = inW - 1;
      if (srcY < 0) srcY = 0; else if (srcY >= inH) srcY = inH - 1;

      final int yIdx = srcY * req.yRowStride + srcX;
      final int uvIdx = (srcY ~/ 2) * req.uvRowStride + (srcX ~/ 2) * req.uvPixelStride;

      // Bound checks
      if (yIdx >= req.yPlane.length || uvIdx >= req.uPlane.length || uvIdx >= req.vPlane.length) continue;

      final int yVal = req.yPlane[yIdx];
      final int uVal = req.uPlane[uvIdx] - 128; // 0..255 -> -128..127
      final int vVal = req.vPlane[uvIdx] - 128;

      // Integer RGB conversion
      int r = (yVal + (1404 * vVal >> 10)).clamp(0, 255);
      int g = (yVal - (346 * uVal >> 10) - (715 * vVal >> 10)).clamp(0, 255);
      int b = (yVal + (1774 * uVal >> 10)).clamp(0, 255);

      final int pixelIdx = (outY * kInputSize + outX) * 3;
      float32Data[pixelIdx] = r / 255.0;
      float32Data[pixelIdx + 1] = g / 255.0;
      float32Data[pixelIdx + 2] = b / 255.0;
    }
  }
  return float32Data.buffer.asUint8List();
}

// ─── Post-processing ──────────────────────────────────────────────
List<DetectionResult> postProcess(Float32List output) {
  List<DetectionResult> dets = [];
  final int numAnchors = kNumAnchors;

  for (int j = 0; j < numAnchors; j++) {
    double maxScore = 0;
    int maxClassId = 0;
    for (int c = 0; c < kNumClasses; c++) {
      final score = output[(4 + c) * numAnchors + j];
      if (score > maxScore) {
        maxScore = score;
        maxClassId = c;
      }
    }
    
    if (maxScore < kConfThreshold) continue;

    final rawX = output[0 * numAnchors + j];
    final rawY = output[1 * numAnchors + j];
    final rawW = output[2 * numAnchors + j];
    final rawH = output[3 * numAnchors + j];

    double cx = rawX;
    double cy = rawY;
    double w = rawW;
    double h = rawH;

    // Heuristic normalization check
    if (cx > 1.0 || cy > 1.0 || w > 1.0 || h > 1.0) {
       cx /= kInputSize;
       cy /= kInputSize;
       w /= kInputSize;
       h /= kInputSize;
    }

    dets.add(DetectionResult(cx - w / 2, cy - h / 2, w, h, maxClassId, maxScore));
  }

  // NMS
  if (dets.isEmpty) return [];
  dets.sort((a, b) => b.confidence.compareTo(a.confidence));
  List<DetectionResult> result = [];
  List<bool> suppressed = List.filled(dets.length, false);
  for (int i = 0; i < dets.length; i++) {
    if (suppressed[i]) continue;
    result.add(dets[i]);
    for (int j = i + 1; j < dets.length; j++) {
      if (suppressed[j]) continue;
      if (_iou(dets[i], dets[j]) > kIouThreshold) suppressed[j] = true;
    }
  }
  return result;
}

double _iou(DetectionResult a, DetectionResult b) {
  final x1 = max(a.x, b.x);
  final y1 = max(a.y, b.y);
  final x2 = min(a.x + a.w, b.x + b.h);
  final y2 = min(a.y + a.h, b.y + b.h);
  final inter = max(0.0, x2 - x1) * max(0.0, y2 - y1);
  return inter / (a.w * a.h + b.w * b.h - inter + 1e-6);
}

// ─── DTOs ─────────────────────────────────────────────────────────
class InferenceResult {
  final int id;
  final List<DetectionResult> detections;
  final int inferenceTime;
  InferenceResult(this.id, this.detections, this.inferenceTime);
}

// ─── App Entry ────────────────────────────────────────────────────
late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    cameras = [];
  }
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const DentalCariesApp());
}

class DentalCariesApp extends StatelessWidget {
  const DentalCariesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dental Caries Detector',
      home: const DetectionScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─── Detection Screen ─────────────────────────────────────────────
class DetectionScreen extends StatefulWidget {
  const DetectionScreen({super.key});
  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

// ─── Detection Screen State ───────────────────────────────────────
class _DetectionScreenState extends State<DetectionScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  
  // Isolate
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  
  List<DetectionResult> _detections = [];
  String _statusMessage = 'Loading...';
  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _inferenceMs = 0;
  
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAll();
  }

  @override
  void didChangeMetrics() {
    setState(() {});
  }

  Future<void> _initAll() async {
    // Load model bytes
    final modelData = await rootBundle.load('assets/models/best_float16.tflite');
    final modelBytes = modelData.buffer.asUint8List();

    // Spawn Isolate
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(isolateEntry, InitRequest(receivePort.sendPort, modelBytes));
    
    receivePort.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        _startCamera();
      } else if (message is InferenceResult) {
        _onInferenceFinished(message);
      }
    });
  }

  Future<void> _startCamera() async {
     if (cameras.isEmpty) {
       if (mounted) setState(() => _statusMessage = 'No cameras found');
       return;
     }

     final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    
    // Dispose previous controller if exists to free resources
    if (_cameraController != null) {
      await _cameraController!.dispose();
    }

    _cameraController = CameraController(cam, ResolutionPreset.medium, 
      enableAudio: false, 
      imageFormatGroup: ImageFormatGroup.yuv420
    );

    try {
      await _cameraController!.initialize();
      if (mounted) setState(() => _statusMessage = 'Detecting...');
      // Start stream
      await _cameraController!.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('Camera error: $e');
      if (mounted) setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  void _onFrame(CameraImage image) {
    if (_isProcessing || _isolateSendPort == null) return;
    _isProcessing = true;
    
    final deviceOrientation = _cameraController!.value.deviceOrientation;
    int rotation = 90;
    if (deviceOrientation == DeviceOrientation.landscapeLeft) rotation = 0;
    if (deviceOrientation == DeviceOrientation.landscapeRight) rotation = 180;
    if (deviceOrientation == DeviceOrientation.portraitDown) rotation = 270;

    final req = FrameRequest(
      0,
      image.planes[0].bytes,
      image.planes[1].bytes,
      image.planes[2].bytes,
      image.width, image.height,
      image.planes[0].bytesPerRow,
      image.planes[1].bytesPerRow,
      image.planes[1].bytesPerPixel ?? 1,
      rotation
    );
    
    _isolateSendPort!.send(req);
  }

  void _onInferenceFinished(InferenceResult result) {
    if (!mounted) return;
    setState(() {
      _detections = result.detections;
      _inferenceMs = result.inferenceTime;
      _frameCount++;
      final now = DateTime.now();
      final elapsed = now.difference(_lastFpsTime).inMilliseconds;
      if (elapsed >= 1000) {
        _fps = (_frameCount * 1000 / elapsed).round();
        _frameCount = 0;
        _lastFpsTime = now;
      }
      _isProcessing = false; 
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose(); 
    _isolate?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
       return Scaffold(backgroundColor: Colors.black, body: Center(child: Text(_statusMessage, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center)));
    }
    
    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(_cameraController!)),
          ),
          Transform.scale(
            scale: scale,
            child: Center(
               child: AspectRatio(
                 aspectRatio: 1 / _cameraController!.value.aspectRatio,
                 child: CustomPaint(
                    painter: _BoxPainter(detections: _detections),
                 ),
               ),
            ),
          ),
          _buildTopBar(),
          _buildBottomBar(),
        ],
      ),
    );
  }
  
  Widget _buildTopBar() => Positioned(
    top: 0, left: 0, right: 0, 
    child: SafeArea(
      child: Padding(padding: const EdgeInsets.all(16), child: 
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Dental AI', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
          Text('${_inferenceMs}ms  $_fps FPS', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
        ])
      )
    )
  );
  
    Widget _buildBottomBar() => Positioned(
    bottom: 0, left: 0, right: 0,
    child: Container(
      color: Colors.black54,
      padding: const EdgeInsets.all(16),
      child: Text(
        _detections.isEmpty ? 'No detections' : 'Found: ${_detections.length} objects',
        style: const TextStyle(color: Colors.white, fontSize: 16),
        textAlign: TextAlign.center,
      ),
    )
  );
}

class _BoxPainter extends CustomPainter {
  final List<DetectionResult> detections;
  _BoxPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;
    
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final bgPaint = Paint()..color = Colors.black45;
    final textStyle = const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold);

    for (final det in detections) {
      paint.color = det.color;
      
      final left = det.x * size.width;
      final top = det.y * size.height;
      final right = (det.x + det.w) * size.width;
      final bottom = (det.y + det.h) * size.height;
      
      final rect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(rect, paint);
      
      final textSpan = TextSpan(text: '${det.className} ${(det.confidence * 100).toInt()}%', style: textStyle);
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();
      canvas.drawRect(Rect.fromLTWH(left, top - tp.height - 4, tp.width + 8, tp.height + 4), bgPaint);
      tp.paint(canvas, Offset(left + 4, top - tp.height - 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}
