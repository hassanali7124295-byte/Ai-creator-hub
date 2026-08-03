import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../services/conversation_storage_service.dart';

/// Owns the full list of chat conversations: loading/saving them, tracking
/// which one is currently open, and every drawer action (new, rename,
/// delete, pin, select). [ChatScreen] stays the source of truth for the
/// *live* message list while a reply is streaming in — it calls back into
/// this provider to persist and to title conversations, so none of the
/// existing send/regenerate/attachment logic has to change shape.
///
/// Wrapped around the app once in main.dart (alongside [ThemeProvider]) so
/// the conversation list — and the last-opened conversation — survive
/// pushes to History/Settings/Profile and back (Step 17 removed the
/// bottom nav's `IndexedStack`; [ChatScreen] is the app's single root now).
class ConversationProvider extends ChangeNotifier {
  List<Conversation> _conversations = [];
  String? _currentId;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// All conversations, pinned first, each group newest-first — the order
  /// the drawer displays them in.
  List<Conversation> get conversations {
    final sorted = [..._conversations];
    sorted.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return sorted;
  }

  String? get currentId => _currentId;

  Conversation? get current {
    if (_currentId == null) return null;
    try {
      return _conversations.firstWhere((c) => c.id == _currentId);
    } catch (_) {
      return null;
    }
  }

  List<ChatMessage> get currentMessages => current?.messages ?? const [];

  /// Loads persisted conversations (migrating Step-11 single-history data
  /// the first time), then restores whichever conversation was last open —
  /// falling back to the most recently updated one, or a brand-new empty
  /// conversation if there's nothing saved at all. Safe to call more than
  /// once; only the first call does any work.
  Future<void> init() async {
    if (_initialized) return;

    _conversations = await ConversationStorageService.loadConversations();

    if (_conversations.isEmpty) {
      final migrated = await ConversationStorageService.migrateLegacyHistory();
      if (migrated != null) _conversations = [migrated];
    }

    final lastId = await ConversationStorageService.loadLastConversationId();
    if (lastId != null && _conversations.any((c) => c.id == lastId)) {
      _currentId = lastId;
    } else if (_conversations.isNotEmpty) {
      _currentId = conversations.first.id; // most recently updated
    } else {
      final fresh = Conversation.create();
      _conversations = [fresh];
      _currentId = fresh.id;
    }

    _initialized = true;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await ConversationStorageService.saveConversations(_conversations);
    if (_currentId != null) {
      await ConversationStorageService.saveLastConversationId(_currentId!);
    }
  }

  /// Starts a new chat. If the current conversation is already empty (no
  /// messages sent yet), it's reused instead of leaving a duplicate blank
  /// entry in the drawer — matching ChatGPT/Gemini's behavior. Returns the
  /// id of the conversation now current.
  Future<String> startNewConversation() async {
    final existing = current;
    if (existing != null && existing.isEmpty) {
      return existing.id;
    }

    final fresh = Conversation.create();
    _conversations.insert(0, fresh);
    _currentId = fresh.id;
    await _persist();
    notifyListeners();
    return fresh.id;
  }

  Future<void> selectConversation(String id) async {
    if (id == _currentId) return;
    if (!_conversations.any((c) => c.id == id)) return;
    _currentId = id;
    await ConversationStorageService.saveLastConversationId(id);
    notifyListeners();
  }

  /// Replaces the current conversation's messages (called after every send,
  /// regenerate, or attachment-failure bubble) and auto-titles it from the
  /// first user message the first time it gets one.
  Future<void> saveCurrentMessages(List<ChatMessage> messages) async {
    final conversation = current;
    if (conversation == null) return;

    conversation.messages = List<ChatMessage>.from(messages);
    conversation.updatedAt = DateTime.now();

    if (!conversation.hasCustomTitle) {
      final firstUserText = messages
          .where((m) => m.isUser && m.text.trim().isNotEmpty)
          .map((m) => m.text)
          .firstOrNull;
      if (firstUserText != null) {
        conversation.title = Conversation.titleFromText(firstUserText);
      }
    }

    await _persist();
    notifyListeners();
  }

  /// Clears the current conversation's messages but keeps its drawer entry,
  /// resetting it back to an untitled, freshly-startable chat.
  Future<void> clearCurrentMessages() async {
    final conversation = current;
    if (conversation == null) return;

    conversation.messages = [];
    conversation.title = Conversation.defaultTitle;
    conversation.hasCustomTitle = false;
    conversation.updatedAt = DateTime.now();

    await _persist();
    notifyListeners();
  }

  Future<void> renameConversation(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final conversation = _byId(id);
    if (conversation == null) return;

    conversation.title = trimmed;
    conversation.hasCustomTitle = true;
    await _persist();
    notifyListeners();
  }

  Future<void> togglePin(String id) async {
    final conversation = _byId(id);
    if (conversation == null) return;
    conversation.pinned = !conversation.pinned;
    await _persist();
    notifyListeners();
  }

  /// Deletes a conversation. If it was the current one, whatever is now
  /// newest-first in [conversations] becomes current — or, if that was the
  /// only conversation, a fresh empty one is created so the chat screen
  /// always has somewhere to write to.
  Future<void> deleteConversation(String id) async {
    final wasCurrent = id == _currentId;
    _conversations.removeWhere((c) => c.id == id);

    if (wasCurrent) {
      if (_conversations.isNotEmpty) {
        _currentId = conversations.first.id;
      } else {
        final fresh = Conversation.create();
        _conversations = [fresh];
        _currentId = fresh.id;
      }
    }

    await _persist();
    notifyListeners();
  }

  Conversation? _byId(String id) {
    try {
      return _conversations.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
