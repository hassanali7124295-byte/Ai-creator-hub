import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/conversation_provider.dart';
import '../models/conversation.dart';

/// The conversation history sidebar — a Material 3 [Drawer] listing every
/// saved chat, with search, pinning, rename, and delete. Rendered inside
/// [ChatScreen]'s local emerald `Theme` override, so it automatically picks
/// up the same "Emerald + Graphite" palette as the rest of the chat UI.
class ConversationDrawer extends StatefulWidget {
  final String? currentId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNewChat;

  const ConversationDrawer({
    super.key,
    required this.currentId,
    required this.onSelect,
    required this.onNewChat,
  });

  @override
  State<ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<ConversationDrawer> {
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

  /// Builds one [_ConversationTile] per conversation in [list] — shared by
  /// both the "Pinned" and "Recent" sections so the tile-wiring (tap,
  /// rename, delete, pin toggle) only lives in one place.
  List<Widget> _buildTiles(BuildContext context, List<Conversation> list) {
    return [
      for (int i = 0; i < list.length; i++)
        _ConversationTile(
          key: ValueKey(list[i].id),
          conversation: list[i],
          index: i,
          isSelected: list[i].id == widget.currentId,
          onTap: () {
            widget.onSelect(list[i].id);
            Navigator.of(context).pop();
          },
          onRename: () => _rename(context, list[i]),
          onDelete: () => _confirmDelete(context, list[i]),
          onTogglePin: () =>
              context.read<ConversationProvider>().togglePin(list[i].id),
        ),
    ];
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
    if (confirmed == true) {
      await provider.deleteConversation(c.id);
    }
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
    final theme = Theme.of(context);
    final provider = context.watch<ConversationProvider>();
    final all = provider.conversations;
    final filtered = _filter(all);
    final pinned = filtered.where((c) => c.pinned).toList();
    final recents = filtered.where((c) => !c.pinned).toList();

    return Drawer(
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.forum_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Chats',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.tonalIcon(
                onPressed: () {
                  widget.onNewChat();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('New chat'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
            const SizedBox(height: 4),
            Expanded(
              child: all.isEmpty
                  ? _EmptyDrawerState(theme: theme)
                  : filtered.isEmpty
                      ? _NoResultsState(theme: theme, query: _query)
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 12, top: 4),
                          children: [
                            if (pinned.isNotEmpty) ...[
                              _SectionLabel(label: 'Pinned', theme: theme),
                              ..._buildTiles(context, pinned),
                            ],
                            if (recents.isNotEmpty) ...[
                              _SectionLabel(label: 'Recent', theme: theme),
                              ..._buildTiles(context, recents),
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
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
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

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;

  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.index,
    required this.isSelected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onTogglePin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FadeInLeft(
      duration: const Duration(milliseconds: 260),
      delay: Duration(milliseconds: 20 * index.clamp(0, 10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Material(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withOpacity(0.55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    conversation.pinned
                        ? Icons.push_pin_rounded
                        : Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                        color: isSelected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurface,
                      ),
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

class _EmptyDrawerState extends StatelessWidget {
  final ThemeData theme;
  const _EmptyDrawerState({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'No conversations yet',
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
