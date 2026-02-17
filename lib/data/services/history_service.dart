
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/history_item.dart';

class HistoryService {
  static const String _storageKey = 'scan_history';

  static Future<List<HistoryItem>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);
    if (jsonString == null) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList.map((j) => HistoryItem.fromJson(j)).toList();
    } catch (e) {
      print('Error decoding history: $e');
      return [];
    }
  }

  static Future<void> saveScan(HistoryItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await getHistory();
    
    // Add new item to beginning of list
    history.insert(0, item);
    
    // Limit history size if needed (e.g. 100 items)
    if (history.length > 100) {
      history.removeRange(100, history.length);
    }
    
    final jsonList = history.map((item) => item.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(jsonList));
  }

  static Future<void> deleteItem(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await getHistory();
    
    history.removeWhere((item) => item.id == id);
    
    final jsonList = history.map((item) => item.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(jsonList));
  }
}
