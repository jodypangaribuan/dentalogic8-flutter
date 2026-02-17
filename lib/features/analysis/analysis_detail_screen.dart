
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../core/constants.dart';
import '../../data/models/detection.dart';
import '../../data/models/history_item.dart';
import '../../data/services/history_service.dart';
import '../../data/services/onnx_prediction_service.dart';
import '../../widgets/bounding_box_painter.dart';
import '../../widgets/premium_widgets.dart';
import 'package:uuid/uuid.dart';

class AnalysisDetailScreen extends StatefulWidget {
  final String imageUri;
  final String source;
  final String? historyId;

  // For pre-loaded history items
  final String? preLabel;
  final double? preConfidence;
  final List<DetectionResult>? preDetections;
  final int? preInferenceTime;

  const AnalysisDetailScreen({
    super.key,
    required this.imageUri,
    this.source = 'gallery',
    this.historyId,
    this.preLabel,
    this.preConfidence,
    this.preDetections,
    this.preInferenceTime,
  });

  @override
  State<AnalysisDetailScreen> createState() => _AnalysisDetailScreenState();
}

class _AnalysisDetailScreenState extends State<AnalysisDetailScreen> {
  List<DetectionResult> _detections = [];
  String _label = 'D0';
  double _confidence = 0.0;
  int _inferenceTime = 0;
  bool _isAnalyzing = true;
  bool _isSaved = false;
  TreatmentInfo? _treatmentInfo;

  // Get the color for a specific class
  Color _colorForClass(String cls) => treatmentData[cls]?.color ?? AppColors.primary;

  // Main label color
  Color get _labelColor => _colorForClass(_label);

  @override
  void initState() {
    super.initState();
    if (widget.preDetections != null) {
      _detections = widget.preDetections!;
      _label = widget.preLabel ?? 'D0';
      _confidence = widget.preConfidence ?? 0.0;
      _inferenceTime = widget.preInferenceTime ?? 0;
      _treatmentInfo = treatmentData[_label];
      _isAnalyzing = false;
      _isSaved = widget.source == 'history';
    } else {
      _runAnalysis();
    }
  }

  Future<void> _runAnalysis() async {
    final onnxService = OnnxPredictionService();
    try {
      await onnxService.initialize();
      final result = await onnxService.predict(widget.imageUri);
      onnxService.dispose();

      if (mounted) {
        setState(() {
          _detections = result.detections;
          _inferenceTime = result.totalTime;
          _finalizeResults();
        });
      }
    } catch (e) {
      debugPrint('ONNX Analysis Error: $e');
      onnxService.dispose();
      if (mounted) {
        setState(() {
          _detections = [];
          _finalizeResults();
        });
      }
    }
  }

  Future<Size> _getImageSize(String path) async {
    final completer = Completer<Size>();
    final image = FileImage(File(path));
    image.resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((info, _) {
        completer.complete(Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        ));
      }),
    );
    return completer.future;
  }

  void _finalizeResults() {
    _isAnalyzing = false;
    int maxSeverityIdx = 0;
    double maxConf = 0.0;

    if (_detections.isEmpty) {
      _label = 'D0';
      _confidence = 1.0;
    } else {
      for (var det in _detections) {
        int idx = DetectionClass.all.indexOf(det.className);
        if (idx > maxSeverityIdx) {
          maxSeverityIdx = idx;
          maxConf = det.confidence;
        } else if (idx == maxSeverityIdx && det.confidence > maxConf) {
          maxConf = det.confidence;
        }
      }
      _label = DetectionClass.all[maxSeverityIdx];
      _confidence = maxConf;
    }

    _treatmentInfo = treatmentData[_label];

    if (!_isSaved && widget.source != 'history') {
      _saveHistory();
    }
  }

  Future<void> _saveHistory() async {
    final item = HistoryItem(
      id: const Uuid().v4(),
      imageUri: widget.imageUri,
      label: _label,
      confidence: _confidence,
      detections: _detections,
      inferenceTime: _inferenceTime,
      source: widget.source,
      imageWidth: kInputSize,
      imageHeight: kInputSize,
      timestamp: DateTime.now(),
    );

    await HistoryService.saveScan(item);
    setState(() => _isSaved = true);
  }

  Future<void> _deleteHistory() async {
    if (widget.historyId == null) return;
    await HistoryService.deleteItem(widget.historyId!);
    if (mounted) Navigator.pop(context);
  }

  // Calculate detection stats
  Map<String, int> get _detectionStats {
    final stats = <String, int>{};
    for (var d in _detections) {
      stats[d.className] = (stats[d.className] ?? 0) + 1;
    }
    return stats;
  }

  // Get unique detected classes sorted by severity (highest first)
  List<String> get _detectedClasses {
    final stats = _detectionStats;
    final classes = stats.keys.toList();
    final order = ['D6', 'D5', 'D4', 'D3', 'D2', 'D1', 'D0'];
    classes.sort((a, b) => order.indexOf(a) - order.indexOf(b));
    return classes;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Detail Analisis', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (widget.historyId != null)
            IconButton(
              icon: const Icon(Icons.delete, color: AppColors.error),
              onPressed: _deleteHistory,
            )
        ],
      ),
      body: _isAnalyzing
          ? const Center(child: PremiumLoadingSpinner(message: 'Menganalisis gigi...'))
          : Stack(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildImagePreview(),
                      const SizedBox(height: 16),
                      _buildResultCard(),
                      const SizedBox(height: 16),
                      if (_detections.isNotEmpty) ...[
                        _buildDetectionDistribution(),
                        const SizedBox(height: 16),
                      ],
                      _buildAllTreatments(),
                      const SizedBox(height: 16),
                      _buildDisclaimer(),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
                // Fullscreen handled as overlay via Navigator
              ],
            ),
    );
  }

  // ── Image Preview ──
  Widget _buildImagePreview() {
    return GestureDetector(
      onTap: () => _openFullscreen(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Container(
              width: double.infinity,
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return FutureBuilder<Size>(
                    future: _getImageSize(widget.imageUri),
                    builder: (context, snapshot) {
                      final imageSize = snapshot.data ?? const Size(640, 640);
                      final containerWidth = constraints.maxWidth;
                      final aspectRatio = imageSize.width / imageSize.height;
                      final displayHeight = containerWidth / aspectRatio;

                      return SizedBox(
                        width: containerWidth,
                        height: displayHeight,
                        child: Stack(
                          children: [
                            Image.file(
                              File(widget.imageUri),
                              fit: BoxFit.contain,
                              width: containerWidth,
                              height: displayHeight,
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: BoundingBoxPainter(detections: _detections),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            // Zoom indication
            Positioned(
              bottom: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.zoom_in, color: Colors.white70, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Result Card ──
  Widget _buildResultCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with badge
          Row(
            children: [
              Container(
                width: 60, height: 60,
                decoration: BoxDecoration(
                  color: _labelColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(_label, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _treatmentInfo?.severity ?? 'Unknown',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.text),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Kepercayaan: ${(_confidence * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Confidence Bar
          const SizedBox(height: 16),
          Container(
            height: 10,
            decoration: BoxDecoration(
              color: const Color(0xFFE2E8F0),
              borderRadius: BorderRadius.circular(5),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: _confidence.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: _labelColor,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),

          // Description
          const SizedBox(height: 20),
          const Text('Deskripsi', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text)),
          const SizedBox(height: 8),
          Text(
            _treatmentInfo?.description ?? '',
            style: const TextStyle(fontSize: 14, color: Color(0xFF64748B), height: 1.55),
          ),
        ],
      ),
    );
  }

  // ── Detection Distribution Grid ──
  Widget _buildDetectionDistribution() {
    final stats = _detectionStats;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Distribusi Karies Terdeteksi', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text)),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const itemCount = 7;
              const spacing = 6.0;
              final totalSpacing = spacing * (itemCount - 1);
              final itemW = (constraints.maxWidth - totalSpacing) / itemCount;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: ['D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6'].map((cls) {
                  final clsColor = _colorForClass(cls);
                  final count = stats[cls] ?? 0;
                  final isActive = count > 0;
                  return SizedBox(
                    width: itemW,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: isActive ? clsColor : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isActive ? clsColor : const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        children: [
                          Text(cls, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isActive ? Colors.white : const Color(0xFF94A3B8))),
                          Text(count.toString(), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: isActive ? Colors.white : const Color(0xFF64748B))),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── All Treatment Recommendations ──
  Widget _buildAllTreatments() {
    // Get all unique detected classes, sorted by severity (highest first)
    final classesToShow = _detectedClasses.isNotEmpty ? _detectedClasses : [_label];
    final stats = _detectionStats;

    debugPrint('Treatment: label=$_label, detectedClasses=$classesToShow, stats=$stats');

    return Column(
      children: classesToShow.map((cls) {
        final info = treatmentData[cls];
        if (info == null) {
          debugPrint('Treatment: No treatmentData for class $cls');
          return const SizedBox.shrink();
        }
        final clsColor = _colorForClass(cls);
        final count = stats[cls] ?? 0;
        final isPrimary = cls == _label;

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: badge + title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: clsColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(cls, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isPrimary
                          ? 'Rekomendasi Penanganan'
                          : '${info.severity} ($count terdeteksi)',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(info.description, style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.5)),
              const SizedBox(height: 14),
              // Numbered treatment items
              ...info.treatment.asMap().entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 22, height: 22,
                        decoration: BoxDecoration(
                          color: clsColor,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text('${entry.key + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(entry.value, style: const TextStyle(fontSize: 13, color: Color(0xFF475569), height: 1.4)),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Disclaimer ──
  Widget _buildDisclaimer() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F9FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBAE6FD)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Hasil analisis ini merupakan alat bantu diagnosis dan tidak menggantikan pemeriksaan langsung oleh dokter gigi profesional.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  // ── Fullscreen Viewer with Pinch-to-Zoom ──
  void _openFullscreen() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                children: [
                  Center(
                    child: InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 4.0,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return FutureBuilder<Size>(
                            future: _getImageSize(widget.imageUri),
                            builder: (context, snapshot) {
                              final imageSize = snapshot.data ?? const Size(640, 640);
                              final sw = constraints.maxWidth;
                              final sh = constraints.maxHeight;
                              final aspectRatio = imageSize.width / imageSize.height;

                              double dw, dh;
                              if (sw / sh > aspectRatio) {
                                dh = sh * 0.9;
                                dw = dh * aspectRatio;
                              } else {
                                dw = sw;
                                dh = dw / aspectRatio;
                              }

                              return SizedBox(
                                width: dw,
                                height: dh,
                                child: Stack(
                                  children: [
                                    Image.file(
                                      File(widget.imageUri),
                                      fit: BoxFit.contain,
                                      width: dw,
                                      height: dh,
                                    ),
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: BoundingBoxPainter(detections: _detections),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  // Close button
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 10,
                    right: 20,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(Icons.close, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
