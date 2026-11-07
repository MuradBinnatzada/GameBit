import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/state/milestones_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/app_choice_chip.dart';
import 'package:checkpoint/widgets/milestone_badge.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// Lets the signed-in member pick the frame around their photo, the title under
/// their name and up to three milestones to show off. What they haven't earned
/// is listed too, locked, with what earns it.
Future<void> showProfileFlairSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ProfileFlairSheet(),
    );

class ProfileFlairSheet extends StatefulWidget {
  const ProfileFlairSheet({super.key});

  @override
  State<ProfileFlairSheet> createState() => _ProfileFlairSheetState();
}

class _ProfileFlairSheetState extends State<ProfileFlairSheet> {
  late ProfileFlair _draft = context.read<ProfileStore>().flair;
  bool _saving = false;
  String? _error;

  void _set({
    String? frameId,
    String? titleId,
    List<String>? showcaseIds,
    bool clearFrame = false,
    bool clearTitle = false,
  }) {
    setState(() {
      _error = null;
      _draft = ProfileFlair(
        frameId: clearFrame ? null : (frameId ?? _draft.frameId),
        titleId: clearTitle ? null : (titleId ?? _draft.titleId),
        showcaseIds: showcaseIds ?? _draft.showcaseIds,
      );
    });
  }

  void _toggleShowcase(String id) {
    final ids = [..._draft.showcaseIds];
    if (!ids.remove(id)) {
      if (ids.length >= ProfileFlair.maxShowcase) {
        setState(
          () => _error = context.l10n.showcaseFull(ProfileFlair.maxShowcase),
        );
        return;
      }
      ids.add(id);
    }
    _set(showcaseIds: ids);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final error = await context.read<ProfileStore>().setFlair(_draft);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final profile = context.watch<ProfileStore>().profile;
    final earned = context.watch<MilestonesStore>().earned;
    final level = earned.level.level;

    return SheetFrame(
      title: context.l10n.profileFlair,
      subtitle: context.l10n.profileFlairSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A preview of the header as others will see it.
          Center(
            child: Column(
              children: [
                FramedAvatar(
                  size: 76,
                  frame: _draft.frame,
                  level: level,
                  child: ProfileAvatar(
                    name: profile.name,
                    size: 76,
                    imageUrl: profile.avatarUrl,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  profile.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (milestoneById(_draft.titleId) case final titled?)
                  ProfileTitleText(milestone: titled),
                if (_draft.showcase.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final m in _draft.showcase)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: MilestoneBadge(milestone: m, size: 30),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 22),
          _Heading(context.l10n.flairFrame),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _FrameOption(
                label: context.l10n.none,
                selected: _draft.frameId == null,
                onTap: () => _set(clearFrame: true),
                child: ProfileAvatar(
                  name: profile.name,
                  size: 44,
                  imageUrl: profile.avatarUrl,
                ),
              ),
              for (final frame in AvatarFrame.values)
                _FrameOption(
                  label: frame.label,
                  selected: _draft.frameId == frame.id,
                  lockedHint: earned.has(frame.milestone.id)
                      ? null
                      : frame.milestone.title,
                  onTap: () => _set(frameId: frame.id),
                  child: FramedAvatar(
                    size: 44 - 2 * FramedAvatar.inset(44),
                    frame: frame,
                    animate: false,
                    child: ProfileAvatar(
                      name: profile.name,
                      size: 44 - 2 * FramedAvatar.inset(44),
                      imageUrl: profile.avatarUrl,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          _Heading(context.l10n.flairTitle),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppChoiceChip(
                label: context.l10n.none,
                selected: _draft.titleId == null,
                onSelected: () => _set(clearTitle: true),
              ),
              for (final m in milestones)
                if (m.rewardTitle case final title?)
                  if (earned.has(m.id))
                    AppChoiceChip(
                      label: title,
                      selected: _draft.titleId == m.id,
                      onSelected: () => _set(titleId: m.id),
                    )
                  else
                    Tooltip(
                      message: context.l10n.unlockWith(m.title),
                      child: Chip(
                        avatar: Icon(
                          Icons.lock_rounded,
                          size: 16,
                          color: palette.muted,
                        ),
                        label: Text(
                          title,
                          style: TextStyle(color: palette.muted),
                        ),
                        backgroundColor: palette.surfaceHigh,
                        side: BorderSide(color: palette.hairline),
                        shape: const StadiumBorder(),
                      ),
                    ),
            ],
          ),
          const SizedBox(height: 22),
          _Heading(
            context.l10n.showcaseHeading(_draft.showcaseIds.length, ProfileFlair.maxShowcase),
          ),
          if (earned.isEmpty)
            Text(
              context.l10n.showcaseEmpty,
              style: TextStyle(color: palette.muted),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in earned.list)
                  _ShowcaseOption(
                    milestone: m,
                    selected: _draft.showcaseIds.contains(m.id),
                    onTap: () => _toggleShowcase(m.id),
                  ),
              ],
            ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              style: TextStyle(color: palette.legible(palette.danger)),
            ),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? context.l10n.saving : context.l10n.save),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
}

/// A frame to pick: the photo in it and its name. A locked one can't be picked
/// and says which milestone earns it.
class _FrameOption extends StatelessWidget {
  const _FrameOption({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
    this.lockedHint,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  /// The milestone that earns it; null when it is unlocked.
  final String? lockedHint;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final locked = lockedHint != null;
    final option = InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: locked ? null : onTap,
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? palette.accent : palette.hairline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Opacity(
              opacity: locked ? 0.35 : 1,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(child: child),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (locked) ...[
                  Icon(Icons.lock_rounded, size: 12, color: palette.muted),
                  const SizedBox(width: 2),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: locked ? palette.muted : palette.textSoft,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return Semantics(
      selected: selected,
      button: true,
      enabled: !locked,
      label: locked ? context.l10n.frameLockedLabel(label, lockedHint!) : context.l10n.frameLabel(label),
      excludeSemantics: true,
      child: locked
          ? Tooltip(message: context.l10n.unlockWith(lockedHint!), child: option)
          : option,
    );
  }
}

/// A milestone to show off, ticked when it is one of the three.
class _ShowcaseOption extends StatelessWidget {
  const _ShowcaseOption({
    required this.milestone,
    required this.selected,
    required this.onTap,
  });

  final Milestone milestone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: milestone.title,
      child: Semantics(
        selected: selected,
        button: true,
        label: milestone.title,
        excludeSemantics: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? palette.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: MilestoneBadge(milestone: milestone, size: 44),
              ),
              if (selected)
                PositionedDirectional(
                  end: -2,
                  top: -2,
                  child: Container(
                    decoration: BoxDecoration(
                      color: palette.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.surface, width: 2),
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.check_rounded,
                      size: 12,
                      color: palette.onAccent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
