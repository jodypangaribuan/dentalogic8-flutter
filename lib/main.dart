import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;

// ─── Model Constants ──────────────────────────────────────────────
const int kInputSize = 640;
const int kNumClasses = 7;
const int kNumOutputs = 8400; // number of detection anchors
const double kConfThreshold = 0.45;
const double kIouThreshold = 0.5;

const List<String> classNames = ['D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6'];
const List<String> classDescriptions = [
  'No Caries',
  'Initial Lesion',
  'Enamel Caries',
  'Dentin Caries',
  'Deep Caries',
  'Pulp Involvement',
  'Root Caries',
];

// Severity colors: green (healthy) → red (severe)
const List<Color> classColors = [
  Color(0xFF4CAF50), // D0 - Green
  Color(0xFF8BC34A), // D1 - Light Green
  Color(0xFFFFEB3B), // D2 - Yellow
  Color(0xFFFF9800), // D3 - Orange
  Color(0xFFFF5722), // D4 - Deep Orange
  Color(0xFFF44336), // D5 - Red
  Color(0xFF9C27B0), // D6 - Purple
];

// ─── Detection Result ─────────────────────────────────────────────
class DetectionResult {
  final double x, y, w, h;
  final int classId;
  final double confidence;

  DetectionResult({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.classId,
    required this.confidence,
  });

  String get className => classNames[classId];
  String get description => classDescriptions[classId];
  Color get color => classColors[classId];
}

// ─── App Entry ────────────────────────────────────────────────────
late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  OrtEnv.instance.init();
  runApp(const DentalCariesApp());
}

// ─── App Root ─────────────────────────────────────────────────────
class DentalCariesApp extends StatelessWidget {
  const DentalCariesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dental Caries Detector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF58A6FF),
          secondary: const Color(0xFF79C0FF),
          surface: const Color(0xFF161B22),
        ),
        fontFamily: 'Roboto',
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
                // App icon
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF58A6FF), Color(0xFF79C0FF)],
                    ),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF58A6FF).withValues(alpha: 0.3),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.medical_services_rounded,
                    size: 60,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 32),
                // Title
                const Text(
                  'Dental Caries\nDetector',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.5,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Real-time AI-powered detection using YOLO',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 48),
                // Class legend
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DETECTION CLASSES',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List.generate(kNumClasses, (i) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: classColors[i].withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: classColors[i].withValues(alpha: 0.4),
                              ),
                            ),
                            child: Text(
                              '${classNames[i]}: ${classDescriptions[i]}',
                              style: TextStyle(
                                fontSize: 12,
                                color: classColors[i],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        }),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                // Start button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DetectionScreen(),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF58A6FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt_rounded, size: 24),
                        SizedBox(width: 12),
                        Text(
                          'Start Detection',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
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
  OrtSession? _session;
  bool _isModelLoaded = false;
  bool _isProcessing = false;
  List<DetectionResult> _detections = [];
  String _statusMessage = 'Loading model...';
  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  Future<void> _initModel() async {
    try {
      // Load model
      setState(() => _statusMessage = 'Loading ONNX model...');
      final sessionOptions = OrtSessionOptions();
      final rawAsset = await rootBundle.load('assets/models/best.onnx');
      final bytes = rawAsset.buffer.asUint8List();
      _session = OrtSession.fromBuffer(bytes, sessionOptions);

      setState(() {
        _isModelLoaded = true;
        _statusMessage = 'Model loaded. Starting camera...';
      });

      // Init camera
      await _initCamera();
    } catch (e) {
      setState(() => _statusMessage = 'Error loading model: $e');
    }
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) {
      setState(() => _statusMessage = 'No cameras available');
      return;
    }

    // Use the back camera
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      setState(() => _statusMessage = 'Detecting...');

      // Start image stream
      _cameraController!.startImageStream(_onCameraFrame);
    } catch (e) {
      setState(() => _statusMessage = 'Camera error: $e');
    }
  }

  void _onCameraFrame(CameraImage cameraImage) {
    if (_isProcessing || !_isModelLoaded) return;
    _isProcessing = true;
    _processFrame(cameraImage);
  }

  Future<void> _processFrame(CameraImage cameraImage) async {
    try {
      // Convert camera image to RGB and resize to 640x640
      final inputData = _preprocessImage(cameraImage);

      // Create input tensor [1, 3, 640, 640]
      final inputOrt = OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(inputData),
        [1, 3, kInputSize, kInputSize],
      );

      final inputs = {'images': inputOrt};
      final runOptions = OrtRunOptions();

      // Run inference
      final outputs = await _session?.runAsync(runOptions, inputs);

      if (outputs != null && outputs.isNotEmpty) {
        final outputTensor = outputs[0];
        if (outputTensor != null) {
          final outputData = outputTensor.value as List;
          final detections = _postProcess(outputData);

          if (mounted) {
            setState(() {
              _detections = detections;
              _updateFps();
            });
          }
          outputTensor.release();
        }
      }

      inputOrt.release();
      runOptions.release();
    } catch (e) {
      // Silently handle frame processing errors
    } finally {
      _isProcessing = false;
    }
  }

  void _updateFps() {
    _frameCount++;
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsTime).inMilliseconds;
    if (elapsed >= 1000) {
      _fps = (_frameCount * 1000 / elapsed).round();
      _frameCount = 0;
      _lastFpsTime = now;
    }
  }

  /// Converts YUV420 camera image to a normalized float32 list in CHW format
  List<double> _preprocessImage(CameraImage image) {
    // Convert YUV420 to RGB
    final int width = image.width;
    final int height = image.height;

    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    // Create an image and resize
    final rgbImage = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * image.planes[0].bytesPerRow + x;
        final int uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

        final int yVal = yPlane[yIndex];
        final int uVal = uPlane[uvIndex];
        final int vVal = vPlane[uvIndex];

        int r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        int g =
            (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128))
                .round()
                .clamp(0, 255);
        int b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

        rgbImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    // Resize to 640x640
    final resized = img.copyResize(
      rgbImage,
      width: kInputSize,
      height: kInputSize,
      interpolation: img.Interpolation.linear,
    );

    // Convert to CHW format normalized to [0, 1]
    final float32Data = List<double>.filled(3 * kInputSize * kInputSize, 0);
    for (int y = 0; y < kInputSize; y++) {
      for (int x = 0; x < kInputSize; x++) {
        final pixel = resized.getPixel(x, y);
        final idx = y * kInputSize + x;
        float32Data[0 * kInputSize * kInputSize + idx] = pixel.r / 255.0; // R
        float32Data[1 * kInputSize * kInputSize + idx] = pixel.g / 255.0; // G
        float32Data[2 * kInputSize * kInputSize + idx] = pixel.b / 255.0; // B
      }
    }

    return float32Data;
  }

  /// Post-process YOLO output [1, 11, 8400] → list of detections
  /// Format: 11 = 4 (x_center, y_center, w, h) + 7 (class scores)
  List<DetectionResult> _postProcess(List outputData) {
    // outputData is [1][11][8400] → flatten to get the 2D [11][8400]
    final List<List<double>> output = [];
    final batch = outputData[0]; // [11][8400]

    for (int i = 0; i < 11; i++) {
      final row = batch[i];
      final List<double> rowData = [];
      for (int j = 0; j < kNumOutputs; j++) {
        rowData.add((row[j] as num).toDouble());
      }
      output.add(rowData);
    }

    // Gather raw detections
    List<DetectionResult> rawDetections = [];

    for (int j = 0; j < kNumOutputs; j++) {
      // Find max class score
      double maxScore = 0;
      int maxClassId = 0;
      for (int c = 0; c < kNumClasses; c++) {
        final score = output[4 + c][j];
        if (score > maxScore) {
          maxScore = score;
          maxClassId = c;
        }
      }

      if (maxScore >= kConfThreshold) {
        final cx = output[0][j] / kInputSize;
        final cy = output[1][j] / kInputSize;
        final w = output[2][j] / kInputSize;
        final h = output[3][j] / kInputSize;

        rawDetections.add(DetectionResult(
          x: cx - w / 2,
          y: cy - h / 2,
          w: w,
          h: h,
          classId: maxClassId,
          confidence: maxScore,
        ));
      }
    }

    // Non-Maximum Suppression
    return _nms(rawDetections, kIouThreshold);
  }

  List<DetectionResult> _nms(List<DetectionResult> dets, double iouThresh) {
    if (dets.isEmpty) return [];

    // Sort by confidence descending
    dets.sort((a, b) => b.confidence.compareTo(a.confidence));

    List<DetectionResult> result = [];

    List<bool> suppressed = List.filled(dets.length, false);

    for (int i = 0; i < dets.length; i++) {
      if (suppressed[i]) continue;
      result.add(dets[i]);

      for (int j = i + 1; j < dets.length; j++) {
        if (suppressed[j]) continue;
        if (_iou(dets[i], dets[j]) > iouThresh) {
          suppressed[j] = true;
        }
      }
    }

    return result;
  }

  double _iou(DetectionResult a, DetectionResult b) {
    final x1 = max(a.x, b.x);
    final y1 = max(a.y, b.y);
    final x2 = min(a.x + a.w, b.x + b.w);
    final y2 = min(a.y + a.h, b.y + b.h);

    final interArea = max(0.0, x2 - x1) * max(0.0, y2 - y1);
    final aArea = a.w * a.h;
    final bArea = b.w * b.h;

    return interArea / (aArea + bArea - interArea + 1e-6);
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _session?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            _buildCameraPreview()
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Color(0xFF58A6FF)),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            ),

          // Bounding box overlay
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            _buildDetectionOverlay(),

          // Top bar
          _buildTopBar(),

          // Bottom stats bar
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final size = MediaQuery.of(context).size;
    final previewSize = _cameraController!.value.previewSize!;
    final previewAspect = previewSize.height / previewSize.width;

    return Center(
      child: AspectRatio(
        aspectRatio: previewAspect,
        child: CameraPreview(_cameraController!),
      ),
    );
  }

  Widget _buildDetectionOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: DetectionPainter(
            detections: _detections,
            previewSize: _cameraController!.value.previewSize!,
            screenSize: Size(constraints.maxWidth, constraints.maxHeight),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.7),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // Back button
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                    color: Colors.white,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: 12),
                // Title
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live Detection',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Dental Caries • YOLO',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
                const Spacer(),
                // FPS badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _fps > 10
                            ? const Color(0xFF4CAF50).withValues(alpha: 0.2)
                            : const Color(0xFFFF5722).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          _fps > 10
                              ? const Color(0xFF4CAF50).withValues(alpha: 0.5)
                              : const Color(0xFFFF5722).withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    '$_fps FPS',
                    style: TextStyle(
                      color: _fps > 10
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFFF5722),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final detectionCount = _detections.length;
    // Get unique classes detected
    final classSet = _detections.map((d) => d.classId).toSet();

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.85),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Detection chips
                if (_detections.isNotEmpty)
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _detections.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final det = _detections[index];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: det.color.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: det.color.withValues(alpha: 0.6),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: det.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${det.className} ${(det.confidence * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: det.color,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                // Stats row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildStatItem(
                      Icons.search,
                      '$detectionCount',
                      'Detected',
                    ),
                    _buildStatItem(
                      Icons.category,
                      '${classSet.length}',
                      'Classes',
                    ),
                    _buildStatItem(
                      Icons.speed,
                      '$_fps',
                      'FPS',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF58A6FF), size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

// ─── Detection Painter ────────────────────────────────────────────
class DetectionPainter extends CustomPainter {
  final List<DetectionResult> detections;
  final Size previewSize;
  final Size screenSize;

  DetectionPainter({
    required this.detections,
    required this.previewSize,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final det in detections) {
      final paint = Paint()
        ..color = det.color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;

      // Scale normalized coords to screen
      final left = det.x * size.width;
      final top = det.y * size.height;
      final right = (det.x + det.w) * size.width;
      final bottom = (det.y + det.h) * size.height;

      final rect = Rect.fromLTRB(left, top, right, bottom);

      // Draw rounded bounding box
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
      canvas.drawRRect(rrect, paint);

      // Draw corner accents
      _drawCornerAccents(canvas, rect, det.color);

      // Draw label background
      final label =
          '${det.className} ${(det.confidence * 100).toStringAsFixed(0)}%';
      final textSpan = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final labelWidth = textPainter.width + 16;
      final labelHeight = textPainter.height + 8;

      final labelRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top - labelHeight - 4, labelWidth, labelHeight),
        const Radius.circular(6),
      );

      final bgPaint = Paint()..color = det.color;
      canvas.drawRRect(labelRect, bgPaint);

      textPainter.paint(
        canvas,
        Offset(left + 8, top - labelHeight - 4 + 4),
      );
    }
  }

  void _drawCornerAccents(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerLen = 14.0;

    // Top-left
    canvas.drawLine(
      Offset(rect.left, rect.top + cornerLen),
      Offset(rect.left, rect.top),
      paint,
    );
    canvas.drawLine(
      Offset(rect.left, rect.top),
      Offset(rect.left + cornerLen, rect.top),
      paint,
    );

    // Top-right
    canvas.drawLine(
      Offset(rect.right - cornerLen, rect.top),
      Offset(rect.right, rect.top),
      paint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.top),
      Offset(rect.right, rect.top + cornerLen),
      paint,
    );

    // Bottom-left
    canvas.drawLine(
      Offset(rect.left, rect.bottom - cornerLen),
      Offset(rect.left, rect.bottom),
      paint,
    );
    canvas.drawLine(
      Offset(rect.left, rect.bottom),
      Offset(rect.left + cornerLen, rect.bottom),
      paint,
    );

    // Bottom-right
    canvas.drawLine(
      Offset(rect.right - cornerLen, rect.bottom),
      Offset(rect.right, rect.bottom),
      paint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.bottom),
      Offset(rect.right, rect.bottom - cornerLen),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant DetectionPainter oldDelegate) {
    return oldDelegate.detections != detections;
  }
}
