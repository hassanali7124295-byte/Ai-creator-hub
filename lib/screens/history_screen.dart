import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/conversation_provider.dart';
import '../core/theme/chat_palette.dart';
import '../models/conversation.dart';
import 'chat_screen.dart';

/// The full-page History screen (Step 16), now reached from the drawer's
/// "History" item (Step 17 removed the bottom nav tab) instead of a tab —
/// every saved conversation with search, pin, rename, delete. Tapping a
/// conversation switches Chat to it and pops straight back.
///
/// Shares [ConversationProvider] with [ChatScreen] (both are handed the
/// same instance from `main.dart`'s `MultiProvider`).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Conversation> _filter(List<Conversation> all) {
    if (_query.trim().isEmpty) return all;
    final q = _query.trim().toLowerCase();
    return all.where((c) => c.title.toLowerCase().contains(q)).toList();
  }

  void _openConversation(BuildContext context, String id) {
    // ChatScreen sits directly beneath History in the Navigator stack
    // (Step 17 — no more bottom-nav tabs) — switch its conversation, then
    // pop back to reveal it, exactly like tapping the same conversation
    // in the drawer would.
    ChatScreen.switchToConversation(context, id);
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete(BuildContext context, Conversation c) async {
    final provider = context.read<ConversationProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          'This will permanently delete "${c.title}". This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await provider.deleteConversation(c.id);
  }

  Future<void> _rename(BuildContext context, Conversation c) async {
    final provider = context.read<ConversationProvider>();
    final controller = TextEditingController(text: c.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: 'Conversation name'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.trim().isNotEmpty) {
      await provider.renameConversation(c.id, newTitle);
    }
  }

  @override
  Widget build(BuildContext context) {
    // History shares Chat's "Emerald + Graphite" palette so the whole
    // conversation-management experience (drawer + this tab) reads as one
    // consistent surface rather than two different apps stitched together.
    final theme = ChatPalette.themeFor(context);
    final provider = context.watch<ConversationProvider>();
    final all = provider.conversations;
    final filtered = _filter(all);
    final pinned = filtered.where((c) => c.pinned).toList();
    final recents = filtered.where((c) => !c.pinned).toList();

    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('History'),
          titleTextStyle: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search conversations',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                ),
              ),
            ),
            Expanded(
              child: all.isEmpty
                  ? _EmptyHistoryState(theme: theme)
                  : filtered.isEmpty
                      ? _NoResultsState(theme: theme, query: _query)
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                          children: [
                            if (pinned.isNotEmpty) ...[
                              _SectionLabel(label: 'Pinned', theme: theme),
                              for (int i = 0; i < pinned.length; i++)
                                _HistoryTile(
                                  key: ValueKey(pinned[i].id),
                                  conversation: pinned[i],
                                  index: i,
                                  isCurrent: pinned[i].id == provider.currentId,
                                  onTap: () =>
                                      _openConversation(context, pinned[i].id),
                                  onRename: () => _rename(context, pinned[i]),
                                  onDelete: () =>
                                      _confirmDelete(context, pinned[i]),
                                  onTogglePin: () => context
                                      .read<ConversationProvider>()
                                      .togglePin(pinned[i].id),
                                ),
                            ],
                            if (recents.isNotEmpty) ...[
                              _SectionLabel(label: 'Recent', theme: theme),
                              for (int i = 0; i < recents.length; i++)
                                _HistoryTile(
                                  key: ValueKey(recents[i].id),
                                  conversation: recents[i],
                                  index: i,
                                  isCurrent: recents[i].id == provider.currentId,
                                  onTap: () =>
                                      _openConversation(context, recents[i].id),
                                  onRename: () => _rename(context, recents[i]),
                                  onDelete: () =>
                                      _confirmDelete(context, recents[i]),
                                  onTogglePin: () => context
                                      .read<ConversationProvider>()
                                      .togglePin(recents[i].id),
                                ),
                            ],
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final ThemeData theme;
  const _SectionLabel({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final Conversation conversation;
  final int index;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;

  const _HistoryTile({
    super.key,
    required this.conversation,
    required this.index,
    required this.isCurrent,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FadeInUp(
      duration: const Duration(milliseconds: 260),
      delay: Duration(milliseconds: 18 * index.clamp(0, 12)),
      from: 12,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Material(
          color: isCurrent
              ? theme.colorScheme.primaryContainer.withOpacity(0.4)
              : theme.colorScheme.surfaceContainer.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      conversation.pinned
                          ? Icons.push_pin_rounded
                          : Icons.chat_bubble_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${conversation.messages.length} messages',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    tooltip: 'Conversation options',
                    onSelected: (value) {
                      switch (value) {
                        case 'pin':
                          onTogglePin();
                          break;
                        case 'rename':
                          onRename();
                          break;
                        case 'delete':
                          onDelete();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'pin',
                        child: Row(
                          children: [
                            Icon(
                              conversation.pinned
                                  ? Icons.push_pin_outlined
                                  : Icons.push_pin_rounded,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Text(conversation.pinned ? 'Unpin' : 'Pin'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'rename',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined, size: 18),
                            SizedBox(width: 10),
                            Text('Rename'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Delete',
                              style:
                                  TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyHistoryState extends StatelessWidget {
  final ThemeData theme;
  const _EmptyHistoryState({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.forum_outlined,
                size: 40,
                color: theme.colorScheme.primary.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No conversations yet',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Chats you start show up here once you send a message.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoResultsState extends StatelessWidget {
  final ThemeData theme;
  final String query;
  const _NoResultsState({required this.theme, required this.query});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No conversations match "$query"',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
