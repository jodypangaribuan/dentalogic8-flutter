import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ─── Model Constants ──────────────────────────────────────────────
const int kInputSize = 640;
const int kNumClasses = 7;
const int kNumAnchors = 8400;
const double kConfThreshold = 0.25;
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

// ─── Isolate preprocessing ────────────────────────────────────────
class PreprocessRequest {
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width, height;
  final int yRowStride, uvRowStride, uvPixelStride;
  PreprocessRequest(this.yPlane, this.uPlane, this.vPlane,
      this.width, this.height, this.yRowStride, this.uvRowStride, this.uvPixelStride);
}

/// Run in isolate: YUV420 → float32 NHWC [1,640,640,3]
List<List<List<List<double>>>> preprocessInIsolate(PreprocessRequest r) {
  // Create NHWC tensor: [1][640][640][3]
  final tensor = List.generate(1, (_) =>
    List.generate(kInputSize, (_) =>
      List.generate(kInputSize, (_) =>
        List.filled(3, 0.0))));

  for (int outY = 0; outY < kInputSize; outY++) {
    final int srcY = (outY * r.height) ~/ kInputSize;
    final int yRowBase = srcY * r.yRowStride;
    final int uvRow = (srcY ~/ 2) * r.uvRowStride;

    for (int outX = 0; outX < kInputSize; outX++) {
      final int srcX = (outX * r.width) ~/ kInputSize;
      final int yIdx = yRowBase + srcX;
      final int uvIdx = uvRow + (srcX ~/ 2) * r.uvPixelStride;

      if (yIdx >= r.yPlane.length || uvIdx >= r.uPlane.length || uvIdx >= r.vPlane.length) continue;

      final int yVal = r.yPlane[yIdx];
      final int uVal = r.uPlane[uvIdx];
      final int vVal = r.vPlane[uvIdx];

      // YUV → RGB (BT.601)
      int red = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
      int green = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).round().clamp(0, 255);
      int blue = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

      tensor[0][outY][outX][0] = red / 255.0;
      tensor[0][outY][outX][1] = green / 255.0;
      tensor[0][outY][outX][2] = blue / 255.0;
    }
  }
  return tensor;
}

// ─── Post-processing (NMS) ────────────────────────────────────────
List<DetectionResult> postProcess(List<List<List<double>>> rawOutput) {
  // rawOutput shape: [1][11][8400] → access [0] = [11][8400]
  final output = rawOutput[0]; // [11][8400]
  List<DetectionResult> dets = [];

  for (int j = 0; j < kNumAnchors; j++) {
    double maxScore = 0;
    int maxClassId = 0;
    for (int c = 0; c < kNumClasses; c++) {
      final score = output[4 + c][j];
      if (score > maxScore) {
        maxScore = score;
        maxClassId = c;
      }
    }
    if (maxScore < kConfThreshold) continue;

    final cx = output[0][j] / kInputSize;
    final cy = output[1][j] / kInputSize;
    final w = output[2][j] / kInputSize;
    final h = output[3][j] / kInputSize;

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
  final x2 = min(a.x + a.w, b.x + b.w);
  final y2 = min(a.y + a.h, b.y + b.h);
  final inter = max(0.0, x2 - x1) * max(0.0, y2 - y1);
  return inter / (a.w * a.h + b.w * b.h - inter + 1e-6);
}

// ─── App Entry ────────────────────────────────────────────────────
late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const DentalCariesApp());
}

class DentalCariesApp extends StatelessWidget {
  const DentalCariesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dental Caries Detector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF58A6FF),
          secondary: Color(0xFF79C0FF),
          surface: Color(0xFF161B22),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─── Home Screen ──────────────────────────────────────────────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D1117), Color(0xFF161B22), Color(0xFF1C2333)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF58A6FF), Color(0xFF79C0FF)]),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [BoxShadow(color: const Color(0xFF58A6FF).withValues(alpha: 0.3), blurRadius: 30, spreadRadius: 5)],
                  ),
                  child: const Icon(Icons.medical_services_rounded, size: 60, color: Colors.white),
                ),
                const SizedBox(height: 32),
                const Text('Dental Caries\nDetector', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white, height: 1.2)),
                const SizedBox(height: 12),
                Text('Real-time AI detection using YOLO', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.white.withValues(alpha: 0.6))),
                const SizedBox(height: 48),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DETECTION CLASSES', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                          letterSpacing: 1.2, color: Colors.white.withValues(alpha: 0.5))),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: List.generate(7, (i) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: classColors[i].withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: classColors[i].withValues(alpha: 0.4)),
                        ),
                        child: Text('${classNames[i]}: ${classDescriptions[i]}',
                            style: TextStyle(fontSize: 12, color: classColors[i], fontWeight: FontWeight.w500)),
                      ))),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                SizedBox(
                  width: double.infinity, height: 56,
                  child: ElevatedButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DetectionScreen())),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF58A6FF), foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), elevation: 0),
                    child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.camera_alt_rounded, size: 24), SizedBox(width: 12),
                      Text('Start Detection', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
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
  bool _isModelLoaded = false;
  bool _isProcessing = false;
  List<DetectionResult> _detections = [];
  String _statusMessage = 'Loading...';
  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsTime = DateTime.now();
  int _inferenceMs = 0;

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
      // Try GPU delegate
      try {
        options.addDelegate(GpuDelegateV2());
        debugPrint('✅ GPU delegate added');
      } catch (_) {
        debugPrint('⚠️ GPU delegate not available, using CPU');
      }

      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float16.tflite',
        options: options,
      );

      // Log tensor info
      final inTensors = _interpreter!.getInputTensors();
      final outTensors = _interpreter!.getOutputTensors();
      debugPrint('Input: ${inTensors.map((t) => '${t.name} ${t.shape}').join(', ')}');
      debugPrint('Output: ${outTensors.map((t) => '${t.name} ${t.shape}').join(', ')}');

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
      setState(() => _statusMessage = 'No cameras');
      return;
    }
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(cam, ResolutionPreset.medium, enableAudio: false,
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
      // Copy planes before async gap
      final req = PreprocessRequest(
        Uint8List.fromList(image.planes[0].bytes),
        Uint8List.fromList(image.planes[1].bytes),
        Uint8List.fromList(image.planes[2].bytes),
        image.width, image.height,
        image.planes[0].bytesPerRow,
        image.planes[1].bytesPerRow,
        image.planes[1].bytesPerPixel ?? 1,
      );

      // Preprocess in isolate (YUV → NHWC float tensor)
      final inputTensor = await Isolate.run(() => preprocessInIsolate(req));

      if (_interpreter == null || !mounted) { _isProcessing = false; return; }

      // Allocate output buffer: [1][11][8400]
      final output = List.generate(1, (_) =>
        List.generate(11, (_) =>
          List.filled(8400, 0.0)));

      // Run inference
      _interpreter!.run(inputTensor, output);

      // Post-process
      final detections = postProcess(output);

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
      _isProcessing = false;
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        if (_cameraController != null && _cameraController!.value.isInitialized)
          SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: SizedBox(
            width: _cameraController!.value.previewSize!.height,
            height: _cameraController!.value.previewSize!.width,
            child: CameraPreview(_cameraController!),
          )))
        else
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF58A6FF)),
            const SizedBox(height: 16),
            Text(_statusMessage, style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ])),

        // Bounding boxes
        if (_cameraController != null && _cameraController!.value.isInitialized)
          LayoutBuilder(builder: (ctx, constraints) => CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _BoxPainter(detections: _detections),
          )),

        // Top bar
        Positioned(top: 0, left: 0, right: 0, child: Container(
          decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
          )),
          child: SafeArea(bottom: false, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Container(
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                child: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 20), color: Colors.white,
                    onPressed: () => Navigator.pop(context)),
              ),
              const SizedBox(width: 12),
              const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Live Detection', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                Text('Dental Caries • YOLO • Real-time', style: TextStyle(color: Colors.white60, fontSize: 12)),
              ]),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Text('${_inferenceMs}ms', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF4CAF50).withValues(alpha: 0.5)),
                ),
                child: Text('$_fps FPS', style: const TextStyle(color: Color(0xFF4CAF50), fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ]),
          )),
        )),

        // Bottom bar
        Positioned(bottom: 0, left: 0, right: 0, child: Container(
          decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.bottomCenter, end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.85), Colors.transparent],
          )),
          child: SafeArea(top: false, child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_detections.isNotEmpty) SizedBox(height: 36, child: ListView.separated(
                scrollDirection: Axis.horizontal, itemCount: _detections.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final d = _detections[i];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: d.color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: d.color.withValues(alpha: 0.6)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: d.color, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text('${d.className} ${(d.confidence * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: d.color, fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                  );
                },
              )),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _stat(Icons.search, '${_detections.length}', 'Detected'),
                _stat(Icons.category, '${_detections.map((d) => d.classId).toSet().length}', 'Classes'),
                _stat(Icons.speed, '$_fps', 'FPS'),
              ]),
            ]),
          )),
        )),
      ]),
    );
  }

  Widget _stat(IconData icon, String value, String label) => Column(children: [
    Icon(icon, color: const Color(0xFF58A6FF), size: 20),
    const SizedBox(height: 4),
    Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
    Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
  ]);
}

// ─── Bounding Box Painter ─────────────────────────────────────────
class _BoxPainter extends CustomPainter {
  final List<DetectionResult> detections;
  _BoxPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    for (final det in detections) {
      final left = det.x * size.width;
      final top = det.y * size.height;
      final right = (det.x + det.w) * size.width;
      final bottom = (det.y + det.h) * size.height;
      final rect = Rect.fromLTRB(left, top, right, bottom);

      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()..color = det.color..strokeWidth = 2.5..style = PaintingStyle.stroke);

      // Corners
      final cp = Paint()..color = det.color..strokeWidth = 3.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
      const c = 14.0;
      canvas.drawLine(Offset(rect.left, rect.top + c), Offset(rect.left, rect.top), cp);
      canvas.drawLine(Offset(rect.left, rect.top), Offset(rect.left + c, rect.top), cp);
      canvas.drawLine(Offset(rect.right - c, rect.top), Offset(rect.right, rect.top), cp);
      canvas.drawLine(Offset(rect.right, rect.top), Offset(rect.right, rect.top + c), cp);
      canvas.drawLine(Offset(rect.left, rect.bottom - c), Offset(rect.left, rect.bottom), cp);
      canvas.drawLine(Offset(rect.left, rect.bottom), Offset(rect.left + c, rect.bottom), cp);
      canvas.drawLine(Offset(rect.right - c, rect.bottom), Offset(rect.right, rect.bottom), cp);
      canvas.drawLine(Offset(rect.right, rect.bottom), Offset(rect.right, rect.bottom - c), cp);

      // Label
      final label = '${det.className} ${(det.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final lw = tp.width + 16;
      final lh = tp.height + 8;
      final ly = (top - lh - 4).clamp(0.0, size.height - lh);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(left, ly, lw, lh), const Radius.circular(6)),
          Paint()..color = det.color);
      tp.paint(canvas, Offset(left + 8, ly + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => old.detections != detections;
}
