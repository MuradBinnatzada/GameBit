import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/state/blocks_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/milestone_badge.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';

/// Opens the members the signed-in one blocked.
void openBlockedMembers(BuildContext context) => unawaited(
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const BlockedMembersScreen())),
);

/// The members the signed-in one blocked, each with a button to unblock them.
class BlockedMembersScreen extends StatefulWidget {
  const BlockedMembersScreen({super.key});

  @override
  State<BlockedMembersScreen> createState() => _BlockedMembersScreenState();
}

class _BlockedMembersScreenState extends State<BlockedMembersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<BlocksStore>().load());
    });
  }

  Future<void> _unblock(SocialUser member) async {
    final store = context.read<BlocksStore>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await store.unblock(member.id);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(l10n.memberUnblocked(member.name))),
        );
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.blockFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = context.watch<BlocksStore>();
    final members = store.blocked;

    Widget body;
    if (store.status == LoadStatus.failed) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.blockedLoadFailed,
        message: l10n.checkConnection,
        actionLabel: l10n.tryAgain,
        onAction: () => unawaited(store.load()),
      );
    } else if (store.status != LoadStatus.ready) {
      body = const Center(child: CircularProgressIndicator());
    } else if (members.isEmpty) {
      body = EmptyState(
        icon: Icons.person_off_outlined,
        title: l10n.noBlockedMembers,
        message: l10n.noBlockedMembersMessage,
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: members.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: context.palette.hairline),
        itemBuilder: (_, i) => _BlockedTile(
          member: members[i],
          onUnblock: () => unawaited(_unblock(members[i])),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.blockedMembers)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: body,
        ),
      ),
    );
  }
}

class _BlockedTile extends StatelessWidget {
  const _BlockedTile({required this.member, required this.onUnblock});

  final SocialUser member;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final frame = member.flair.frame;
    final photo = frame == null ? 44.0 : 44 - 2 * FramedAvatar.inset(44);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 44,
            child: Center(
              child: FramedAvatar(
                size: photo,
                frame: frame,
                child: ProfileAvatar(
                  name: member.name,
                  size: photo,
                  imageUrl: member.avatarUrl,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  member.handle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onUnblock,
            child: Text(context.l10n.unblock),
          ),
        ],
      ),
    );
  }
}
