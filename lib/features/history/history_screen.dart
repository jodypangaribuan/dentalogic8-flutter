
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../data/services/history_service.dart';
import '../../data/models/history_item.dart';
import 'package:intl/intl.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryItem> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }
  
  // Reload when revisiting (FocusEffect in RN, here we can use route observer or just init)
  // Since we don't have a tab controller yet that keeps state alive, building it might reload it.
  // If we assume standard nav, popping back to it might not rebuild unless we update.
  
  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final data = await HistoryService.getHistory();
    if (mounted) {
      setState(() {
         _history = data;
         _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
               padding: const EdgeInsets.all(24),
               child: Row(
                 mainAxisAlignment: MainAxisAlignment.spaceBetween,
                 children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                         Text('Riwayat', style: AppTextStyles.h1),
                         Text('${_history.length} Analisis Tersimpan', style: AppTextStyles.body),
                      ],
                    ),
                    IconButton(icon: const Icon(Icons.refresh), onPressed: _loadHistory)
                 ],
               ),
            ),
            
            Expanded(
              child: _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : _history.isEmpty 
                   ? Center(
                       child: Column(
                         mainAxisAlignment: MainAxisAlignment.center,
                         children: [
                            const Icon(Icons.history, size: 64, color: Colors.grey),
                            const SizedBox(height: 16),
                            Text('Belum ada riwayat', style: AppTextStyles.h3.copyWith(color: Colors.grey)),
                         ],
                       )
                   )
                   : ListView.builder(
                       padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                       itemCount: _history.length,
                       itemBuilder: (context, index) {
                         final item = _history[index];
                         return GestureDetector(
                           onTap: () async {
                              await Navigator.pushNamed(
                                context, 
                                '/analysis-detail',
                                arguments: {
                                  'imageUri': item.imageUri,
                                  'source': 'history',
                                  'initialDetections': item.detections,
                                  'historyId': item.id,
                                  'preLabel': item.label,
                                  'preConfidence': item.confidence,
                                  'preInferenceTime': item.inferenceTime,
                                }
                              );
                              _loadHistory(); // Reload in case deleted
                           },
                           child: Container(
                             margin: const EdgeInsets.only(bottom: 16),
                             padding: const EdgeInsets.all(12),
                             decoration: BoxDecoration(
                               color: Colors.white,
                               borderRadius: BorderRadius.circular(16),
                               boxShadow: [
                                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))
                               ]
                             ),
                             child: Row(
                               children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(
                                      File(item.imageUri), 
                                      width: 72, height: 72, fit: BoxFit.cover,
                                      errorBuilder: (c,e,s) => Container(color: Colors.grey[200], width: 72, height: 72, child: const Icon(Icons.broken_image)),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                         Row(
                                           children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                decoration: BoxDecoration(
                                                   color: AppColors.background, // Should use severity color
                                                   borderRadius: BorderRadius.circular(6)
                                                ),
                                                child: Text(item.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                              ),
                                              const Spacer(),
                                              Text(DateFormat('dd MMM yyyy').format(item.timestamp), style: AppTextStyles.caption),
                                           ],
                                         ),
                                         const SizedBox(height: 6),
                                         Text('${item.detections.length} Deteksi', style: AppTextStyles.bodyBold),
                                         Text('${(item.confidence * 100).toInt()}% Akurat', style: AppTextStyles.caption),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right, color: Colors.grey),
                               ],
                             ),
                           ),
                         );
                       },
                   ),
            ),
          ],
        ),
      ),
    );
  }
}
