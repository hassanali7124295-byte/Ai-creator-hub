import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/chat_message.dart';

/// Saves and restores the AI Chat conversation so it survives app restarts.
class ChatStorageService {
  ChatStorageService._();

  static const String _historyPrefKey = 'chat_history';

  static Future<List<ChatMessage>> loadMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyPrefKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupted/old-format history shouldn't crash the app — just start fresh.
      return [];
    }
  }

  static Future<void> saveMessages(List<ChatMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(messages.map((m) => m.toJson()).toList());
    await prefs.setString(_historyPrefKey, encoded);
  }

  static Future<void> clearMessages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyPrefKey);
  }
}
