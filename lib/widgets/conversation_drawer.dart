import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/providers/conversation_provider.dart';
import '../models/conversation.dart';
import '../screens/about_screen.dart';
import '../screens/history_screen.dart';
import '../screens/privacy_policy_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/settings_screen.dart';

/// The conversation history sidebar — a Material 3 [Drawer] listing every
/// saved chat, with search, pinning, rename, and delete. Rendered inside
/// [ChatScreen]'s local emerald `Theme` override, so it automatically picks
/// up the same "Emerald + Graphite" palette as the rest of the chat UI.
///
/// Step 17: this is now the app's *only* navigation surface (the bottom
/// nav bar is gone). Besides the conversation list, it links out to the
/// full History screen, Settings, Profile, Rate App, Privacy Policy, and
/// About Pak AI via [_DrawerNavSection] at the bottom.
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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          theme.colorScheme.primary,
                          theme.colorScheme.primary.withOpacity(0.6),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withOpacity(0.35),
                          blurRadius: 16,
                          spreadRadius: 0.5,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.forum_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pak AI',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'v1.0.0',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            const SizedBox(height: 8),
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
            const Divider(height: 1, indent: 16, endIndent: 16),
            const _DrawerNavSection(),
          ],
        ),
      ),
    );
  }
}

/// Step 17: the drawer's bottom navigation block — everything that used
/// to live in the removed bottom nav bar (History, Settings, Profile),
/// plus Rate App / Privacy Policy / About Pak AI. Each item pushes a full
/// screen on top of [ChatScreen] and closes the drawer first.
class _DrawerNavSection extends StatelessWidget {
  const _DrawerNavSection();

  static const String _playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.aicreatorhub.ai_creator_hub';

  Future<void> _rateApp(BuildContext context) async {
    Navigator.of(context).pop();
    final uri = Uri.parse(_playStoreUrl);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the Play Store.')),
      );
    }
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <({IconData icon, String label, VoidCallback onTap})>[
      (
        icon: Icons.history_rounded,
        label: 'History',
        onTap: () => _push(context, const HistoryScreen()),
      ),
      (
        icon: Icons.settings_outlined,
        label: 'Settings',
        onTap: () => _push(context, const SettingsScreen()),
      ),
      (
        icon: Icons.person_outline_rounded,
        label: 'Profile',
        onTap: () => _push(context, const ProfileScreen()),
      ),
      (
        icon: Icons.star_outline_rounded,
        label: 'Rate App',
        onTap: () => _rateApp(context),
      ),
      (
        icon: Icons.privacy_tip_outlined,
        label: 'Privacy Policy',
        onTap: () => _push(context, const PrivacyPolicyScreen()),
      ),
      (
        icon: Icons.info_outline_rounded,
        label: 'About Pak AI',
        onTap: () => _push(context, const AboutScreen()),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: item.onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    child: Row(
                      children: [
                        Icon(item.icon,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 16),
                        Text(
                          item.label,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
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
