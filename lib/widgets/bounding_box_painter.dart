
import 'package:flutter/material.dart';
import '../data/models/detection.dart';
import '../core/theme.dart';

class BoundingBoxPainter extends CustomPainter {
  final List<DetectionResult> detections;
  final double scaleX;
  final double scaleY;

  BoundingBoxPainter({
    required this.detections,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final bgPaint = Paint()..color = Colors.black54;

    for (final det in detections) {
      paint.color = det.color;

      // Calculate coordinates
      // det.x, y, w, h are normalized (0..1)
      final left = det.x * size.width * scaleX;
      final top = det.y * size.height * scaleY;
      final width = det.w * size.width * scaleX;
      final height = det.h * size.height * scaleY;

      // Draw Box
      final rect = Rect.fromLTWH(left, top, width, height);
      canvas.drawRect(rect, paint);

      // Draw Label Background
      final textSpan = TextSpan(
        text: '${det.className} ${(det.confidence * 100).toInt()}%',
        style: AppTextStyles.caption.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
      );
      final tp = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();


      // Ensure label doesn't go off screen
      double labelY = top - tp.height - 4;
      if (labelY < 0) labelY = top + height; // Move to bottom if top is clipped

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, labelY, tp.width + 8, tp.height + 4),
          const Radius.circular(4)
        ),
        bgPaint
      );
      
      tp.paint(canvas, Offset(left + 4, labelY + 2));
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) => true;
}
