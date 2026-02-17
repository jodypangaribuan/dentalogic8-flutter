

import 'detection.dart';

class HistoryItem {
  final String id;
  final String imageUri;
  final String label;
  final double confidence;
  final List<DetectionResult> detections;
  final int inferenceTime;
  final String source;
  final int imageWidth;
  final int imageHeight;
  final DateTime timestamp;

  HistoryItem({
    required this.id,
    required this.imageUri,
    required this.label,
    required this.confidence,
    required this.detections,
    required this.inferenceTime,
    this.source = 'local',
    required this.imageWidth,
    required this.imageHeight,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'imageUri': imageUri,
      'label': label,
      'confidence': confidence,
      'detections': detections.map((d) => d.toJson()).toList(),
      'inferenceTime': inferenceTime,
      'source': source,
      'imageWidth': imageWidth,
      'imageHeight': imageHeight,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    return HistoryItem(
      id: json['id'],
      imageUri: json['imageUri'],
      label: json['label'],
      confidence: (json['confidence'] as num).toDouble(),
      detections: (json['detections'] as List)
          .map((d) => DetectionResult.fromJson(d))
          .toList(),
      inferenceTime: json['inferenceTime'] as int,
      source: json['source'] ?? 'local',
      imageWidth: json['imageWidth'] ?? 640,
      imageHeight: json['imageHeight'] ?? 640,
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}
