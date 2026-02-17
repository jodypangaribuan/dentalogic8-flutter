import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import '../models/detection.dart';
import '../../core/constants.dart';

class OnnxPredictionService {
  final OnnxRuntime _ort = OnnxRuntime();
  OrtSession? _session;

  Future<void> initialize() async {
    _session = await _ort.createSessionFromAsset(
      'assets/models/best.onnx',
    );
    debugPrint('ONNX Session Created. Inputs: ${_session!.inputNames}, Outputs: ${_session!.outputNames}');
  }

  Future<OnnxInferenceResult> predict(String imagePath) async {
    if (_session == null) {
      throw Exception('ONNX session not initialized');
    }

    final sw = Stopwatch()..start();

    // 1. Load and preprocess image
    final file = File(imagePath);
    final bytes = await file.readAsBytes();
    img.Image? image = img.decodeImage(bytes);

    if (image == null) {
      return OnnxInferenceResult([], 0);
    }

    final resized = img.copyResize(image, width: kInputSize, height: kInputSize);

    // 2. Convert to Float32 normalized [0,1] in NCHW format
    // YOLO ONNX expects [1, 3, 640, 640] in NCHW format
    final inputData = List<double>.filled(3 * kInputSize * kInputSize, 0.0);

    for (var y = 0; y < kInputSize; y++) {
      for (var x = 0; x < kInputSize; x++) {
        final pixel = resized.getPixel(x, y);
        final idx = y * kInputSize + x;
        inputData[0 * kInputSize * kInputSize + idx] = pixel.r / 255.0; // R channel
        inputData[1 * kInputSize * kInputSize + idx] = pixel.g / 255.0; // G channel
        inputData[2 * kInputSize * kInputSize + idx] = pixel.b / 255.0; // B channel
      }
    }

    final preprocessTime = sw.elapsedMilliseconds;

    // 3. Create input tensor
    final inputName = _session!.inputNames.first;
    final inputTensor = await OrtValue.fromList(
      inputData,
      [1, 3, kInputSize, kInputSize],
    );

    // 4. Run inference
    final swInf = Stopwatch()..start();
    final outputs = await _session!.run({inputName: inputTensor});
    swInf.stop();
    final inferenceTime = swInf.elapsedMilliseconds;

    // 5. Post-process output
    final swPost = Stopwatch()..start();

    final outputName = _session!.outputNames.first;
    final outputValue = outputs[outputName];

    if (outputValue == null) {
      return OnnxInferenceResult([], preprocessTime + inferenceTime);
    }

    final outputRaw = await outputValue.asFlattenedList();
    final outputData = List<double>.generate(outputRaw.length, (i) => (outputRaw[i] as num).toDouble());
    
    debugPrint('ONNX Output: ${outputData.length} elements');
    debugPrint('ONNX Expected: ${(4 + kNumClasses) * kNumAnchors} elements (${4 + kNumClasses} x $kNumAnchors)');
    
    // Print some sample values to understand the output format
    if (outputData.length >= 20) {
      debugPrint('ONNX First 20 values: ${outputData.sublist(0, 20)}');
    }
    
    // Find max confidence across all anchors to debug threshold issues
    double maxConfFound = 0;
    final numRows = 4 + kNumClasses; // 11
    final numCols = outputData.length ~/ numRows; // auto-detect
    debugPrint('ONNX Auto-detected shape: $numRows x $numCols (total: ${numRows * numCols})');
    
    if (numRows * numCols == outputData.length) {
      for (int col = 0; col < numCols; col++) {
        for (int cls = 0; cls < kNumClasses; cls++) {
          final score = outputData[(4 + cls) * numCols + col];
          if (score > maxConfFound) maxConfFound = score;
        }
      }
    }
    debugPrint('ONNX Max confidence found: $maxConfFound (threshold: $kConfThreshold)');

    final detections = _postProcess(outputData, numRows, numCols);
    debugPrint('ONNX Detections found: ${detections.length}');
    for (var d in detections) {
      debugPrint('  Detection: ${d.className} conf=${d.confidence.toStringAsFixed(3)} box=(${d.x.toStringAsFixed(3)}, ${d.y.toStringAsFixed(3)}, ${d.w.toStringAsFixed(3)}, ${d.h.toStringAsFixed(3)})');
    }

    swPost.stop();
    final postprocessTime = swPost.elapsedMilliseconds;

    sw.stop();

    // Clean up
    inputTensor.dispose();
    outputValue.dispose();

    return OnnxInferenceResult(
      detections,
      sw.elapsedMilliseconds,
      preprocessTime: preprocessTime,
      inferenceTime: inferenceTime,
      postprocessTime: postprocessTime,
    );
  }

  List<DetectionResult> _postProcess(
    List<double> output,
    int numRows,
    int numCols,
  ) {
    // Output format: [1, numRows, numCols] flattened
    // Row 0-3: cx, cy, w, h
    // Row 4+: class probabilities

    List<DetectionResult> candidates = [];

    for (int col = 0; col < numCols; col++) {
      // Find best class
      double maxScore = 0;
      int bestClass = 0;

      for (int cls = 0; cls < kNumClasses; cls++) {
        final score = output[(4 + cls) * numCols + col];
        if (score > maxScore) {
          maxScore = score;
          bestClass = cls;
        }
      }

      if (maxScore < kConfThreshold) continue;

      final cx = output[0 * numCols + col];
      final cy = output[1 * numCols + col];
      final w = output[2 * numCols + col];
      final h = output[3 * numCols + col];

      // Output is already normalized (0-1), convert cx,cy,w,h to x,y,w,h
      final x1 = cx - w / 2;
      final y1 = cy - h / 2;

      candidates.add(DetectionResult(x1, y1, w, h, bestClass, maxScore));
    }

    // NMS
    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    final List<DetectionResult> results = [];

    while (candidates.isNotEmpty) {
      final best = candidates.removeAt(0);
      results.add(best);

      candidates.removeWhere((candidate) {
        return _iou(best, candidate) > kIouThreshold;
      });
    }

    return results;
  }

  double _iou(DetectionResult a, DetectionResult b) {
    final x1 = max(a.x, b.x);
    final y1 = max(a.y, b.y);
    final x2 = min(a.x + a.w, b.x + b.w);
    final y2 = min(a.y + a.h, b.y + b.h);

    if (x2 <= x1 || y2 <= y1) return 0.0;

    final intersection = (x2 - x1) * (y2 - y1);
    final areaA = a.w * a.h;
    final areaB = b.w * b.h;

    return intersection / (areaA + areaB - intersection);
  }

  void dispose() {
    _session?.close();
  }
}

class OnnxInferenceResult {
  final List<DetectionResult> detections;
  final int totalTime;
  final int preprocessTime;
  final int inferenceTime;
  final int postprocessTime;

  OnnxInferenceResult(
    this.detections,
    this.totalTime, {
    this.preprocessTime = 0,
    this.inferenceTime = 0,
    this.postprocessTime = 0,
  });
}
