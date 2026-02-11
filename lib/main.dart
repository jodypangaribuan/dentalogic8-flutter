import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ─── Model Constants ──────────────────────────────────────────────
const int kInputSize = 640;
const int kNumClasses = 7;
const int kNumAnchors = 8400;
// Increased threshold to reduce noise
const double kConfThreshold = 0.45; 
const double kIouThreshold = 0.45;

const List<String> classNames = ['D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6'];
const List<String> classDescriptions = [
  'No Caries', 'Initial Lesion', 'Enamel Caries',
  'Dentin Caries', 'Deep Caries', 'Pulp Involvement', 'Root Caries',
];
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
  String get className => classNames[classId];
  Color get color => classColors[classId];
}

// ─── Preprocessing (Main Thread - Optimized & Rotated) ─────────────
Float32List preprocessImage(CameraImage image, int sensorOrientation) {
  final totalElements = kInputSize * kInputSize * 3;
  final float32Data = Float32List(totalElements);

  final int width = image.width;
  final int height = image.height;
  final int yRowStride = image.planes[0].bytesPerRow;
  final int uvRowStride = image.planes[1].bytesPerRow;
  final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;
  final Uint8List yPlane = image.planes[0].bytes;
  final Uint8List uPlane = image.planes[1].bytes;
  final Uint8List vPlane = image.planes[2].bytes;

  // Assuming 90 deg rotation for portrait mode (standard on phones)
  final bool rotate90 = sensorOrientation == 90;

  for (int outY = 0; outY < kInputSize; outY++) {
    for (int outX = 0; outX < kInputSize; outX++) {
      
      // Coordinate Mapping with optional rotation
      int srcX, srcY;
      if (rotate90) {
        // 90 deg CW: Dest(x,y) = Src(y, H-1-x)
        // Inverse: Src(x, y) = Dest(y, H-1-x)? No.
        // Let's map Output (outX, outY) back to Source (srcX, srcY)
        // outX corresponds to source Y axis (inverted?) 
        // 90 CW: Top-Left (0,0) -> Top-Right (H,0) in source framing?
        // Standard Android 90:
        // outY (vertical) maps to srcX (horizontal scanning)
        // outX (horizontal) maps to srcY (vertical scanning, inverted)
        
        srcX = (outY * width) ~/ kInputSize;
        srcY = ((kInputSize - 1 - outX) * height) ~/ kInputSize;
      } else {
        srcX = (outX * width) ~/ kInputSize;
        srcY = (outY * height) ~/ kInputSize;
      }

      final int yIdx = srcY * yRowStride + srcX;
      // UV planes are subsampled 2x2
      final int uvIdx = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

      // Bound checks (fast)
      if (yIdx >= yPlane.length || uvIdx >= uPlane.length || uvIdx >= vPlane.length) continue;

      final int yVal = yPlane[yIdx];
      final int uVal = uPlane[uvIdx] - 128;
      final int vVal = vPlane[uvIdx] - 128;

      // Integer approx of BT.601 YUV->RGB for speed
      // R = Y + 1.370705 V
      // G = Y - 0.337633 U - 0.698001 V
      // B = Y + 1.732446 U
      // Using fixed-point math (x1024)
      
      int r = (yVal + (1404 * vVal >> 10)).clamp(0, 255);
      int g = (yVal - (346 * uVal >> 10) - (715 * vVal >> 10)).clamp(0, 255);
      int b = (yVal + (1774 * uVal >> 10)).clamp(0, 255);

      final int pixelIdx = (outY * kInputSize + outX) * 3;
      float32Data[pixelIdx] = r / 255.0;
      float32Data[pixelIdx + 1] = g / 255.0;
      float32Data[pixelIdx + 2] = b / 255.0;
    }
  }
  return float32Data;
}

// ─── Post-processing (NMS) ────────────────────────────────────────
List<DetectionResult> postProcess(Float32List output) {
  List<DetectionResult> dets = [];
  final int numAnchors = kNumAnchors;

  // Debug: print max score in frame to verify normalization
  double frameMaxScore = 0;

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
    if (maxScore > frameMaxScore) frameMaxScore = maxScore;
    
    if (maxScore < kConfThreshold) continue;

    final rawX = output[0 * numAnchors + j];
    final rawY = output[1 * numAnchors + j];
    final rawW = output[2 * numAnchors + j];
    final rawH = output[3 * numAnchors + j];

    double cx = rawX;
    double cy = rawY;
    double w = rawW;
    double h = rawH;

    // Heuristic: If values are large (> 1.0), they are likely pixels.
    if (cx > 1.0 || cy > 1.0 || w > 1.0 || h > 1.0) {
       cx /= kInputSize;
       cy /= kInputSize;
       w /= kInputSize;
       h /= kInputSize;
    }

    dets.add(DetectionResult(cx - w / 2, cy - h / 2, w, h, maxClassId, maxScore));
  }
  
  // Debug one high-confidence detection occasionally
  if (dets.isNotEmpty && DateTime.now().millisecond < 50) {
     final d = dets.first;
     debugPrint('Top det: ${d.className} ${d.confidence} rect=[${d.x.toStringAsFixed(2)}, ${d.y.toStringAsFixed(2)}, ${d.w.toStringAsFixed(2)}, ${d.h.toStringAsFixed(2)}]');
     // Also log raw values of top det (we need to find it in original list effectively, but this is approx)
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
  final x2 = min(a.x + a.w, b.x + b.w);
  final y2 = min(a.y + a.h, b.y + b.h);
  final inter = max(0.0, x2 - x1) * max(0.0, y2 - y1);
  return inter / (a.w * a.h + b.w * b.h - inter + 1e-6);
}

// ─── App Entry ────────────────────────────────────────────────────
late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera init error: $e');
    cameras = [];
  }
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

class _DetectionScreenState extends State<DetectionScreen> {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  Tensor? _inputTensor;
  Tensor? _outputTensor;
  
  bool _isModelLoaded = false;
  bool _isProcessing = false;
  List<DetectionResult> _detections = [];
  String _statusMessage = 'Loading...';
  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _inferenceMs = 0;
  int _sensorOrientation = 90; // Default to 90
  
  // Buffers
  Float32List? _outputBuffer;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _loadModel();
    await _initCamera();
  }

  Future<void> _loadModel() async {
    try {
      setState(() => _statusMessage = 'Loading model...');

      final options = InterpreterOptions()..threads = 4;
      if (Platform.isAndroid) options.addDelegate(GpuDelegateV2());
      if (Platform.isIOS) options.addDelegate(GpuDelegate());

      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float16.tflite',
        options: options,
      );

      _inputTensor = _interpreter!.getInputTensors().first;
      _outputTensor = _interpreter!.getOutputTensors().first;
      _outputBuffer = Float32List(1 * 11 * 8400);

      setState(() {
        _isModelLoaded = true;
        _statusMessage = 'Model ready!';
      });
    } catch (e) {
      debugPrint('Model load error: $e');
      setState(() => _statusMessage = 'Model error: $e');
    }
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) {
      if (cameras.isEmpty) {
         try { cameras = await availableCameras(); } catch (_) {}
      }
      if (cameras.isEmpty) { // Double check
        setState(() => _statusMessage = 'No cameras found');
        return;
      }
    }
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _sensorOrientation = cam.sensorOrientation;
    _cameraController = CameraController(cam, ResolutionPreset.medium, // 480p (720x480) is good for speed
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420);
    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() => _statusMessage = 'Detecting...');
        _cameraController!.startImageStream(_onFrame);
      }
    } catch (e) {
      setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  void _onFrame(CameraImage image) {
    if (_isProcessing || !_isModelLoaded || _interpreter == null) return;
    _isProcessing = true;
    _processFrame(image);
  }

  Future<void> _processFrame(CameraImage image) async {
    final sw = Stopwatch()..start();
    try {
      // 1. Preprocess (Sync on Main Thread to avoid Isolate overhead)
      // On modern phones, this 640x640 loop takes ~15-20ms
      final inputData = preprocessImage(image, _sensorOrientation);

      if (_interpreter == null || !mounted) { _isProcessing = false; return; }

      // 2. Inference
      _inputTensor!.setTo(inputData.buffer.asUint8List());
      _interpreter!.invoke();
      _outputTensor!.copyTo(_outputBuffer!.buffer.asUint8List());

      // 3. Post-process
      final detections = postProcess(_outputBuffer!);

      sw.stop();
      if (mounted) {
        setState(() {
          _detections = detections;
          _inferenceMs = sw.elapsedMilliseconds;
          _frameCount++;
          final now = DateTime.now();
          final elapsed = now.difference(_lastFpsTime).inMilliseconds;
          if (elapsed >= 1000) {
            _fps = (_frameCount * 1000 / elapsed).round();
            _frameCount = 0;
            _lastFpsTime = now;
          }
        });
      }
    } catch (e) {
      debugPrint('Processing error: $e');
    } finally {
      if (mounted) _isProcessing = false;
    }
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
       return Scaffold(backgroundColor: Colors.black, body: Center(child: Text(_statusMessage, style: const TextStyle(color: Colors.white))));
    }
    
    // Correct Aspect Ratio Handling
    // Camera is usually 4:3 (rotated). PreviewSize might be 720x480 (3:2) or 640x480 (4:3).
    final size = MediaQuery.of(context).size;
    
    // Calculate scale to cover screen
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera Preview (Full Screen)
          Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(_cameraController!)),
          ),
          
          // Bounding Boxes - Wrapped in same Transform to line up? 
          // No, CameraPreview scales content. CustomPaint needs to match visible area.
          // Simpler: Use AspectRatio widget to force content to match camera aspect ratio, then fit to screen?
          // Let's rely on coordinate mapping.
          // If Transform.scale zooms in, we just draw on top.
          // The cleanest way: CustomPaint fills screen. We Map 0..1 to Screen Rect.
          // But if CameraPreview is zoomed, 0..1 corresponds to a larger area than screen.
          // We need to apply the same transform to the bounding boxes.
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
          
          // UI Overlays
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

// ─── Bounding Box Painter ─────────────────────────────────────────
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
    final textStyle = const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold);

    for (final det in detections) {
      paint.color = det.color;

      // Coordinates are normalized [0,1]. Map to size.
      // Detections are from the FULL camera frame (e.g. 640x480).
      // Since we wrap CustomPaint in AspectRatio matching camera, 
      // size.width/height matches the full camera frame visible size.
      // So simple multiplication works!
      
      final left = det.x * size.width;
      final top = det.y * size.height;
      final right = (det.x + det.w) * size.width;
      final bottom = (det.y + det.h) * size.height;
      
      final rect = Rect.fromLTRB(left, top, right, bottom);
      canvas.drawRect(rect, paint);

      // Label
      final textSpan = TextSpan(
        text: '${det.className} ${(det.confidence * 100).toInt()}%',
        style: textStyle,
      );
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
      tp.layout();
      
      canvas.drawRect(Rect.fromLTWH(left, top - tp.height - 4, tp.width + 8, tp.height + 4), bgPaint);
      tp.paint(canvas, Offset(left + 4, top - tp.height - 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}
