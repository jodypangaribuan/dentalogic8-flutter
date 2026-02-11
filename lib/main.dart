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

  // Initialize TFLite - Smart Selection
  Interpreter? interpreter;
  Tensor? inputTensor;
  Tensor? outputTensor;
  final outputBuffer = Float32List(1 * 11 * 8400);

  try {
    // 1. Initial load on CPU to check model type
    var options = InterpreterOptions()..threads = 4;
    interpreter = Interpreter.fromBuffer(initReq.modelBytes, options: options);
    interpreter.allocateTensors();
    
    final tempInputTensor = interpreter.getInputTensors().first;
    final isQuantized = tempInputTensor.type == TensorType.uint8;
    
    print("Model Input Type: ${tempInputTensor.type}");

    // 2. Optimization Logic
    if (isQuantized) {
       print("Smart Init: Detected Int8 Model. Keeping CPU (XNNPACK) for best performance.");
       // Already loaded on CPU, keep it.
    } else {
       // Float32 -> Try GPU
       if (Platform.isAndroid) {
          print("Smart Init: Detected Float32 Model. Switching to GPU Delegate...");
          interpreter.close(); // Close CPU interpreter
          
          try {
            options.addDelegate(GpuDelegateV2(
              options: GpuDelegateOptionsV2(isPrecisionLossAllowed: true)
            ));
            interpreter = Interpreter.fromBuffer(initReq.modelBytes, options: options);
            interpreter.allocateTensors();
            print("Smart Init: GPU Initialized Successfully.");
          } catch (e) {
            print("Smart Init: GPU Failed ($e). Falling back to CPU.");
            // Re-open on CPU
            options = InterpreterOptions()..threads = 4;
            interpreter = Interpreter.fromBuffer(initReq.modelBytes, options: options);
            interpreter.allocateTensors();
          }
       }
    }

    inputTensor = interpreter.getInputTensors().first;
    outputTensor = interpreter.getOutputTensors().first;
  } catch (e) {
    print("Isolate Init Error: $e");
  }

    // Prepare buffers based on input type
    final inputType = inputTensor!.type;
    final isQuantized = inputType == TensorType.uint8;
    
    // Create buffers
    Float32List? inputFloatBuffer;
    Uint8List? inputIntBuffer;
    
    if (isQuantized) {
      inputIntBuffer = Uint8List(kInputSize * kInputSize * 3);
      print("Model detected as Int8 (Quantized). Expecting higher FPS.");
    } else {
      inputFloatBuffer = Float32List(kInputSize * kInputSize * 3);
      print("Model detected as Float32. If FPS is low, try an Int8 model.");
    }

    await for (final message in receivePort) {
      if (message is FrameRequest) {
         if (interpreter == null) continue;
         
         int preprocessTime = 0;
         int inferenceTime = 0;
         int postprocessTime = 0;
  
         try {
           // 1. Preprocess
           final swPre = Stopwatch()..start();
           
           Uint8List inputBytes;
           if (isQuantized) {
              _preprocessUint8(message, inputIntBuffer!);
              inputBytes = inputIntBuffer;
           } else {
              _preprocessFloat(message, inputFloatBuffer!);
              inputBytes = inputFloatBuffer.buffer.asUint8List();
           }
           
           swPre.stop();
           preprocessTime = swPre.elapsedMilliseconds;
           
           // 2. Inference
           final swInf = Stopwatch()..start();
           inputTensor!.setTo(inputBytes);
           interpreter.invoke();
           outputTensor!.copyTo(outputBuffer.buffer.asUint8List());
           swInf.stop();
           inferenceTime = swInf.elapsedMilliseconds;
           
           // 3. Postprocess
           final swPost = Stopwatch()..start();
           final detections = postProcess(outputBuffer);
           swPost.stop();
           postprocessTime = swPost.elapsedMilliseconds;
           
           // Send Results back
           initReq.sendPort.send(InferenceResult(
               message.id, 
               detections, 
               preprocessTime + inferenceTime + postprocessTime,
               preprocessTime,
               inferenceTime,
               postprocessTime
           ));
           
           if (message.id % 30 == 0) {
              print("PERF: Pre=$preprocessTime ms, Inf=$inferenceTime ms, Post=$postprocessTime ms");
           }
         } catch (e) {
           print("Pipeline Error: $e");
         }
      }
    }
}

// Optimized Preprocessing for Float32
void _preprocessFloat(FrameRequest req, Float32List outBuffer) {
   _preprocessCommon(req, (r, g, b, offset) {
     outBuffer[offset] = r / 255.0;
     outBuffer[offset + 1] = g / 255.0;
     outBuffer[offset + 2] = b / 255.0;
   });
}

// Optimized Preprocessing for Uint8 (Int8 Models)
void _preprocessUint8(FrameRequest req, Uint8List outBuffer) {
   _preprocessCommon(req, (r, g, b, offset) {
     outBuffer[offset] = r;
     outBuffer[offset + 1] = g;
     outBuffer[offset + 2] = b;
   });
}

// Common rotation/loop logic to avoid code duplication
// Using a higher order function for pixel assignment might slightly reduce performance due to closure, 
// but it's cleaner. Given Pre is 10ms, this is acceptable. 
// For max speed, we would duplicate the loops, but let's try this first.
void _preprocessCommon(FrameRequest req, Function(int r, int g, int b, int offset) storePixel) {
  final int inW = req.width;
  final int inH = req.height;
  final int inW_1 = inW - 1;
  final int inH_1 = inH - 1;

  final yPlane = req.yPlane;
  final uPlane = req.uPlane;
  final vPlane = req.vPlane;
  final yRowStride = req.yRowStride;
  final uvRowStride = req.uvRowStride;
  final uvPixelStride = req.uvPixelStride;

  int pixelIdx = 0;

  // Optimized loops based on rotation
  if (req.rotation == 90) { 
    // Portrait Up
    for (int outY = 0; outY < kInputSize; outY++) {
      final int srcX = (outY * inW) ~/ kInputSize;
      final int srcX_clamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
      for (int outX = 0; outX < kInputSize; outX++) {
         final int srcY = ((kInputSize - 1 - outX) * inH) ~/ kInputSize;
         final int srcY_clamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
         _convertPixel(yPlane, uPlane, vPlane, srcX_clamped, srcY_clamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
         pixelIdx += 3;
      }
    }
  } else if (req.rotation == 270) {
    // Portrait Down
    for (int outY = 0; outY < kInputSize; outY++) {
      final int srcX = ((kInputSize - 1 - outY) * inW) ~/ kInputSize;
      final int srcX_clamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
      for (int outX = 0; outX < kInputSize; outX++) {
        final int srcY = (outX * inH) ~/ kInputSize;
        final int srcY_clamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
        _convertPixel(yPlane, uPlane, vPlane, srcX_clamped, srcY_clamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
        pixelIdx += 3;
      }
    }
  } else if (req.rotation == 180) {
     // Landscape Right
     for (int outY = 0; outY < kInputSize; outY++) {
       final int srcY = ((kInputSize - 1 - outY) * inH) ~/ kInputSize;
       final int srcY_clamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
       for (int outX = 0; outX < kInputSize; outX++) {
         final int srcX = ((kInputSize - 1 - outX) * inW) ~/ kInputSize;
         final int srcX_clamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
         _convertPixel(yPlane, uPlane, vPlane, srcX_clamped, srcY_clamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
         pixelIdx += 3;
       }
     }
  } else {
    // Landscape Left (0)
    for (int outY = 0; outY < kInputSize; outY++) {
      final int srcY = (outY * inH) ~/ kInputSize;
      final int srcY_clamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
      for (int outX = 0; outX < kInputSize; outX++) {
        final int srcX = (outX * inW) ~/ kInputSize;
        final int srcX_clamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
        _convertPixel(yPlane, uPlane, vPlane, srcX_clamped, srcY_clamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
        pixelIdx += 3;
      }
    }
  }
}

@pragma('vm:prefer-inline')
void _convertPixel(
    Uint8List yPlane, Uint8List uPlane, Uint8List vPlane,
    int x, int y,
    int yRowStride, int uvRowStride, int uvPixelStride,
    int outOffset, Function(int r, int g, int b, int offset) storePixel) {
  
  final int yIdx = y * yRowStride + x;
  final int uvIdx = (y >> 1) * uvRowStride + (x >> 1) * uvPixelStride;

  final int yVal = yPlane[yIdx];
  final int uVal = uPlane[uvIdx] - 128; 
  final int vVal = vPlane[uvIdx] - 128;

  int r = yVal + ((1436 * vVal) >> 10);
  int g = yVal - ((352 * uVal + 731 * vVal) >> 10);
  int b = yVal + ((1814 * uVal) >> 10);

  if (r < 0) r = 0; else if (r > 255) r = 255;
  if (g < 0) g = 0; else if (g > 255) g = 255;
  if (b < 0) b = 0; else if (b > 255) b = 255;
  
  storePixel(r, g, b, outOffset);
}

// Inline-friendly helper for YUV -> RGB -> Float32


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
  final int preprocessTime;
  final int inferenceOnlyTime;
  final int postprocessTime;

  InferenceResult(this.id, this.detections, this.inferenceTime, 
      [this.preprocessTime = 0, this.inferenceOnlyTime = 0, this.postprocessTime = 0]);
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
      title: 'dentalogic8',
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
  int _preprocessMs = 0;
  int _postprocessMs = 0;
  
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
      _inferenceMs = result.inferenceOnlyTime; // Show pure inference time
      _preprocessMs = result.preprocessTime;
      _postprocessMs = result.postprocessTime;
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
          Column(
             crossAxisAlignment: CrossAxisAlignment.end,
             children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('UI: $_fps FPS', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(width: 10),
                    Text(
                      'Model: ${_inferenceMs > 0 ? (1000 / (_preprocessMs + _inferenceMs + _postprocessMs)).toStringAsFixed(1) : "0.0"} FPS', 
                      style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 16)
                    ),
                  ],
                ),
                Text('Pre: ${_preprocessMs}ms  Inf: ${_inferenceMs}ms  Post: ${_postprocessMs}ms', style: const TextStyle(color: Colors.white70, fontSize: 12)),
             ]
          )
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
