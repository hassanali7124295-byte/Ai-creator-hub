import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/conversation.dart';
import 'chat_storage_service.dart';

/// Saves and restores the full list of chat conversations, plus which one
/// was last open, so the multi-conversation chat system survives app
/// restarts.
///
/// Superseses the single-thread storage in [ChatStorageService] (Step 11
/// and earlier only ever had one chat history). [migrateLegacyHistory] folds
/// any pre-Step-12 history into a real conversation exactly once, so
/// existing users don't lose their chat on update.
class ConversationStorageService {
  ConversationStorageService._();

  static const String _conversationsPrefKey = 'chat_conversations';
  static const String _lastConversationIdPrefKey = 'last_conversation_id';

  static Future<List<Conversation>> loadConversations() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_conversationsPrefKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupted/old-format data shouldn't crash the app — start fresh.
      return [];
    }
  }

  static Future<void> saveConversations(List<Conversation> conversations) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(conversations.map((c) => c.toJson()).toList());
    await prefs.setString(_conversationsPrefKey, encoded);
  }

  static Future<String?> loadLastConversationId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastConversationIdPrefKey);
  }

  static Future<void> saveLastConversationId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastConversationIdPrefKey, id);
  }

  /// One-time upgrade path: if a Step-11-style single chat history exists
  /// (saved under [ChatStorageService]'s key) and no conversations have
  /// been created yet, wrap that history in a new [Conversation] so it
  /// shows up in the drawer instead of silently disappearing. The legacy
  /// key is cleared afterwards so this only ever runs once.
  static Future<Conversation?> migrateLegacyHistory() async {
    final legacyMessages = await ChatStorageService.loadMessages();
    if (legacyMessages.isEmpty) return null;

    final first = legacyMessages.first.timestamp;
    final last = legacyMessages.last.timestamp;
    final firstUserMessage = legacyMessages
        .where((m) => m.isUser)
        .map((m) => m.text)
        .where((t) => t.trim().isNotEmpty)
        .firstOrNull;

    final conversation = Conversation(
      id: '${first.microsecondsSinceEpoch}-legacy',
      title: firstUserMessage != null
          ? Conversation.titleFromText(firstUserMessage)
          : Conversation.defaultTitle,
      createdAt: first,
      updatedAt: last,
      hasCustomTitle: firstUserMessage != null,
      messages: legacyMessages,
    );

    await ChatStorageService.clearMessages();
    return conversation;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
