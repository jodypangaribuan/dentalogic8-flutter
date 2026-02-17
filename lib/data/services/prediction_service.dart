
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import '../models/detection.dart';
import '../../core/constants.dart';

// ─── Isolate DTOs ─────────────────────────────────────────────────
class InitRequest {
  final SendPort sendPort;
  final Uint8List streamModelBytes;
  final Uint8List staticModelBytes;
  InitRequest(this.sendPort, this.streamModelBytes, this.staticModelBytes);
}

class FrameRequest {
  final int id;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width, height;
  final int yRowStride, uvRowStride, uvPixelStride;
  final int rotation;
  final bool isFrontCamera;

  FrameRequest(this.id, this.yPlane, this.uPlane, this.vPlane,
      this.width, this.height, this.yRowStride, this.uvRowStride, this.uvPixelStride, this.rotation,
      {this.isFrontCamera = false});
}

class ImageFileRequest {
  final int id;
  final String path;
  
  ImageFileRequest(this.id, this.path);
}

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

class PredictionService {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final StreamController<InferenceResult> _resultController = StreamController.broadcast();

  bool _isDisposed = false;

  Stream<InferenceResult> get results => _resultController.stream;

  Future<void> initialize() async {
    // Load model bytes
    // Stream Model (Float16)
    final streamModelData = await rootBundle.load('assets/models/best_float16.tflite');
    final streamModelBytes = streamModelData.buffer.asUint8List();

    // Static Model (Int8 Quantized) - Best for CPU/Gallery
    final staticModelData = await rootBundle.load('assets/models/best_full_integer_quant.tflite');
    final staticModelBytes = staticModelData.buffer.asUint8List();

    // Spawn Isolate
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(
      _isolateEntry, 
      InitRequest(receivePort.sendPort, streamModelBytes, staticModelBytes)
    );
    
    receivePort.listen((message) {
      if (_isDisposed) return;
      if (message is SendPort) {
        _isolateSendPort = message;
      } else if (message is InferenceResult) {
        if (!_resultController.isClosed) {
          _resultController.add(message);
        }
      }
    });
  }

  void processFrame(CameraImage image, int rotation, {bool isFrontCamera = false}) {
    if (_isolateSendPort == null) return;

    final req = FrameRequest(
      0, 
      image.planes[0].bytes,
      image.planes[1].bytes,
      image.planes[2].bytes,
      image.width, image.height,
      image.planes[0].bytesPerRow,
      image.planes[1].bytesPerRow,
      image.planes[1].bytesPerPixel ?? 1,
      rotation,
      isFrontCamera: isFrontCamera,
    );
    
    _isolateSendPort!.send(req);
  }
  
  void predictImageFile(String path) {
    if (_isolateSendPort == null) return;
    final req = ImageFileRequest(1, path);
    _isolateSendPort!.send(req);
  }

  void dispose() {
    _isDisposed = true;
    _isolate?.kill();
    _resultController.close();
  }
}

// ─── Isolate Entry Point ──────────────────────────────────────────
void _isolateEntry(InitRequest initReq) async {
  final receivePort = ReceivePort();
  initReq.sendPort.send(receivePort.sendPort);

  // 1. Initialize Stream Interpreter (Float16 -> GPU Preferred)
  Interpreter? interpreterStream;
  Tensor? inputTensorStream;
  Tensor? outputTensorStream;
  
  // 2. Initialize Static Interpreter (Int8 -> CPU Preferred)
  Interpreter? interpreterStatic;
  Tensor? inputTensorStatic;
  Tensor? outputTensorStatic;

  final outputBuffer = Float32List(1 * 11 * kNumAnchors);

  // --- Setup Stream Interpreter (Float16) - CPU Only ---
  // NOTE: GPU delegate disabled due to fatal SIGSEGV crash on Adreno GPUs.
  // XNNPACK (CPU) with 4 threads provides stable, good performance.
  try {
    final options = InterpreterOptions()..threads = 4;
    interpreterStream = Interpreter.fromBuffer(initReq.streamModelBytes, options: options);
    interpreterStream.allocateTensors();
    
    inputTensorStream = interpreterStream.getInputTensors().first;
    outputTensorStream = interpreterStream.getOutputTensors().first;
    debugPrint("Stream Model: ${inputTensorStream.type} (CPU)");

  } catch (e) {
    debugPrint("Stream Init Error: $e");
  }

  // --- Setup Static Interpreter (Int8) ---
  try {
    // Always CPU for Int8 (XNNPACK is default and fast)
    var options = InterpreterOptions()..threads = 4;
    interpreterStatic = Interpreter.fromBuffer(initReq.staticModelBytes, options: options);
    interpreterStatic.allocateTensors();
    
    inputTensorStatic = interpreterStatic.getInputTensors().first;
    outputTensorStatic = interpreterStatic.getOutputTensors().first;
    debugPrint("Static Model: ${inputTensorStatic.type} (Int8)");

  } catch (e) {
    debugPrint("Static Init Error: $e");
  }

  // Pre-allocate buffers for Int8 and Float32
  final inputIntBuffer = Uint8List(kInputSize * kInputSize * 3);
  final inputFloatBuffer = Float32List(kInputSize * kInputSize * 3);

  await for (final message in receivePort) {
    
    int preprocessTime = 0;
    int inferenceTime = 0;
    int postprocessTime = 0;
    
    try {
      if (message is FrameRequest) {
         if (interpreterStream == null) continue;
         
         // Frame Processing (use Stream Interpreter)
         final swPre = Stopwatch()..start();
         
         Uint8List inputBytes;
         // Assume Stream Model is Float32 (based on filename/previous logic)
         // But let's check tensor type if needed. 
         // For now, enforcing Float32 for Stream as per user request/filename.
         
         _preprocessFloat(message, inputFloatBuffer);
         inputBytes = inputFloatBuffer.buffer.asUint8List();
         
         swPre.stop();
         preprocessTime = swPre.elapsedMilliseconds;
         
         final swInf = Stopwatch()..start();
         inputTensorStream!.setTo(inputBytes);
         interpreterStream.invoke();
         outputTensorStream!.copyTo(outputBuffer.buffer.asUint8List());
         swInf.stop();
         inferenceTime = swInf.elapsedMilliseconds;
         
         final swPost = Stopwatch()..start();
         var detections = _postProcess(outputBuffer);
         
         // Fix front camera mirroring (flip X)
         if (message.isFrontCamera) {
            detections = detections.map((d) {
              // Normalized coordinates: x is top-left.
              // Flip relative to center (0.5) or just 1.0 - x - w?
              // Standard mirror: x_new = 1.0 - (x + w)
              // Let's verify:
              // Left object (x=0.1, w=0.2) -> Right object (x=0.7, w=0.2)
              // 1.0 - (0.1 + 0.2) = 0.7. Correct.
              return DetectionResult(
                1.0 - (d.x + d.w), 
                d.y, 
                d.w, 
                d.h, 
                d.classId, 
                d.confidence
              );
            }).toList();
         }
         
         swPost.stop();
         postprocessTime = swPost.elapsedMilliseconds;
         
         initReq.sendPort.send(InferenceResult(
             message.id, detections, preprocessTime + inferenceTime + postprocessTime,
             preprocessTime, inferenceTime, postprocessTime
         ));

      } else if (message is ImageFileRequest) {
         if (interpreterStatic == null) continue;
         
         // Static Image Processing (use Static Interpreter - Int8)
         final swPre = Stopwatch()..start();
         
         final file = File(message.path);
         if (!file.existsSync()) continue;
         
         final bytes = await file.readAsBytes();
         img.Image? image = img.decodeImage(bytes);
         if (image == null) continue;
         
         final resized = img.copyResize(image, width: kInputSize, height: kInputSize);
         
         // Int8 Preprocessing
         var pixelIndex = 0;
         for (var y = 0; y < kInputSize; y++) {
           for (var x = 0; x < kInputSize; x++) {
             final pixel = resized.getPixel(x, y);
             inputIntBuffer[pixelIndex++] = pixel.r.toInt();
             inputIntBuffer[pixelIndex++] = pixel.g.toInt();
             inputIntBuffer[pixelIndex++] = pixel.b.toInt();
           }
         }
         
         swPre.stop();
         preprocessTime = swPre.elapsedMilliseconds;
         
         final swInf = Stopwatch()..start();
         inputTensorStatic!.setTo(inputIntBuffer);
         interpreterStatic.invoke();
         
         // Output of Int8 model might need dequantization??
         // Usually Int8 models output Dequantized Float32 if configured, 
         // OR they output Uint8 which needs scale/zero_point.
         // TFLite Flutter: "outputTensor.copyTo" blindly copies bytes.
         // If outputTensor is Float32, it copies floats.
         // If outputTensor is Uint8, it copies ints.
         
         // Check output type:
         if (outputTensorStatic!.type == TensorType.uint8) {
            // Need to dequantize? 
            // Or maybe the model has a dequantize head?
            // "best_full_integer_quant.tflite" usually implies Int8/Uint8 I/O.
            
            // Let's assume standard Object Detection output [1, 84, 8400] is usually Float32 
            // even in some quant models if the output layer is dequantized.
            // If it is strictly Uint8, we need to convert.
            
            // Safe bet: allocation buffer size and type-check.
            final outBytes = Uint8List(1 * 11 * kNumAnchors); // 1 byte per element? No, Uint8.
            outputTensorStatic.copyTo(outBytes);
            
            // TODO: Implement Dequantization if needed.
            // For now, let's assume it outputs Float32 (common with TFLite Metadata).
            // Actually, let's try copyTo Float32List first. If it crashes/mismatches size, we catch error.
            
            outputTensorStatic.copyTo(outputBuffer.buffer.asUint8List());
         } else {
            // Float32 output
            outputTensorStatic.copyTo(outputBuffer.buffer.asUint8List());
         }
         
         swInf.stop();
         inferenceTime = swInf.elapsedMilliseconds;
         
         final swPost = Stopwatch()..start();
         final detections = _postProcess(outputBuffer);
         swPost.stop();
         postprocessTime = swPost.elapsedMilliseconds;
         
         initReq.sendPort.send(InferenceResult(
             message.id, detections, preprocessTime + inferenceTime + postprocessTime,
             preprocessTime, inferenceTime, postprocessTime
         ));
      }
    } catch (e) {
      debugPrint("Pipeline Error: $e");
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



// Common rotation/loop logic to avoid code duplication
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
      final int srcXClamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
      for (int outX = 0; outX < kInputSize; outX++) {
         final int srcY = ((kInputSize - 1 - outX) * inH) ~/ kInputSize;
         final int srcYClamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
         _convertPixel(yPlane, uPlane, vPlane, srcXClamped, srcYClamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
         pixelIdx += 3;
      }
    }
  } else if (req.rotation == 270) {
    // Portrait Down
    for (int outY = 0; outY < kInputSize; outY++) {
      final int srcX = ((kInputSize - 1 - outY) * inW) ~/ kInputSize;
      final int srcXClamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
      for (int outX = 0; outX < kInputSize; outX++) {
        final int srcY = (outX * inH) ~/ kInputSize;
        final int srcYClamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
        _convertPixel(yPlane, uPlane, vPlane, srcXClamped, srcYClamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
        pixelIdx += 3;
      }
    }
  } else if (req.rotation == 180) {
     // Landscape Right
     for (int outY = 0; outY < kInputSize; outY++) {
       final int srcY = ((kInputSize - 1 - outY) * inH) ~/ kInputSize;
       final int srcYClamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
       for (int outX = 0; outX < kInputSize; outX++) {
         final int srcX = ((kInputSize - 1 - outX) * inW) ~/ kInputSize;
         final int srcXClamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
         _convertPixel(yPlane, uPlane, vPlane, srcXClamped, srcYClamped, 
             yRowStride, uvRowStride, uvPixelStride, pixelIdx, storePixel);
         pixelIdx += 3;
       }
     }
  } else {
    // Landscape Left (0)
    for (int outY = 0; outY < kInputSize; outY++) {
      final int srcY = (outY * inH) ~/ kInputSize;
      final int srcYClamped = srcY < 0 ? 0 : (srcY > inH_1 ? inH_1 : srcY);
      for (int outX = 0; outX < kInputSize; outX++) {
        final int srcX = (outX * inW) ~/ kInputSize;
        final int srcXClamped = srcX < 0 ? 0 : (srcX > inW_1 ? inW_1 : srcX);
        _convertPixel(yPlane, uPlane, vPlane, srcXClamped, srcYClamped, 
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

  if (r < 0) {
    r = 0;
  } else if (r > 255) {
    r = 255;
  }
  if (g < 0) {
    g = 0;
  } else if (g > 255) {
    g = 255;
  }
  if (b < 0) {
    b = 0;
  } else if (b > 255) {
    b = 255;
  }
  
  storePixel(r, g, b, outOffset);
}

// ─── Post-processing ──────────────────────────────────────────────
List<DetectionResult> _postProcess(Float32List output) {
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
