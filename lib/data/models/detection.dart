
import 'dart:ui';
import '../../core/theme.dart';
import '../../core/constants.dart';

class DetectionResult {
  final double x, y, w, h;
  final int classId;
  final double confidence;

  DetectionResult(this.x, this.y, this.w, this.h, this.classId, this.confidence);

  // Helper to get class name from ID (0 -> D0)
  String get className => DetectionClass.all[classId];

  // Helper to get color
  Color get color => treatmentData[className]?.color ?? AppColors.text;

  // For JSON serialization/deserialization logic if needed later
  Map<String, dynamic> toJson() => {
    'x': x, 'y': y, 'w': w, 'h': h,
    'class': className, 'confidence': confidence
  };
  
  factory DetectionResult.fromJson(Map<String, dynamic> json) {
    // Basic implementation for restoring from history JSON
    // Note: React Native uses [x1,y1,x2,y2] format in some places, 
    // but here we stick to x,y,w,h normalized as per existing Flutter logic.
    // If restoring from generic Map:
    String cls = json['class'] ?? 'D0';
    int clsId = DetectionClass.all.indexOf(cls);
    if (clsId == -1) clsId = 0;
    
    // Check if bbox is array [x1, y1, x2, y2]
    if (json['bbox'] is List) {
       final bbox = json['bbox'] as List;
       double x1 = (bbox[0] as num).toDouble();
       double y1 = (bbox[1] as num).toDouble();
       double x2 = (bbox[2] as num).toDouble();
       double y2 = (bbox[3] as num).toDouble();
       return DetectionResult(x1, y1, x2 - x1, y2 - y1, clsId, (json['confidence'] as num).toDouble());
    }
    
    return DetectionResult(
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
      (json['w'] as num).toDouble(),
      (json['h'] as num).toDouble(),
      clsId,
      (json['confidence'] as num).toDouble(),
    );
  }
}
