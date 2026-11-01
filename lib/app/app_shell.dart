import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/app/auth_gate.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/app/new_password_screen.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/screens/discussions/discussions_screen.dart';
import 'package:checkpoint/screens/lists/lists_screen.dart';
import 'package:checkpoint/screens/onboarding/onboarding_screen.dart';
import 'package:checkpoint/screens/home/home_screen.dart';
import 'package:checkpoint/screens/library/library_screen.dart';
import 'package:checkpoint/screens/profile/profile_screen.dart';
import 'package:checkpoint/screens/search/search_screen.dart';
import 'package:checkpoint/sheets/quick_log_sheet.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/lists_store.dart';
import 'package:checkpoint/state/milestones_store.dart';
import 'package:checkpoint/state/release_alerts_store.dart';
import 'package:checkpoint/state/shared_link_store.dart';
import 'package:checkpoint/state/nav_store.dart';
import 'package:checkpoint/state/onboarding_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/utils/navigation.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _screens = <Widget>[
    HomeScreen(),
    SearchScreen(),
    DiscussionsScreen(),
    AuthGate(child: LibraryScreen()),
    AuthGate(child: ProfileScreen()),
  ];

  late final AuthStore _auth;
  late final LibraryStore _library;
  late final ProfileStore _profile;
  late final ListsStore _lists;
  late final ReleaseAlertsStore _releases;
  late final SharedLinkStore _links;
  late final MilestonesStore _milestones;
  late final OnboardingStore _onboarding;

  /// A shared link is being opened, or sign-in was asked for to open it.
  bool _openingLink = false;
  bool _askedToSignIn = false;

  /// The new password screen a reset link opened is showing.
  bool _askingForPassword = false;

  /// The first-run walk-through is showing.
  bool _walkingThrough = false;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthStore>();
    _library = context.read<LibraryStore>();
    _profile = context.read<ProfileStore>();
    _lists = context.read<ListsStore>();
    _auth.addListener(_askForNewPassword);
    _library.addListener(_showNotices);
    _profile.addListener(_showNotices);
    _lists.addListener(_showNotices);
    _releases = context.read<ReleaseAlertsStore>();
    _releases.addListener(_announceReleases);
    _links = context.read<SharedLinkStore>();
    _auth.addListener(_openLinkAfterFrame);
    _links.addListener(_openLinkAfterFrame);
    _milestones = context.read<MilestonesStore>();
    _milestones.addListener(_announceMilestones);
    _onboarding = context.read<OnboardingStore>();
    _onboarding.addListener(_offerOnboardingAfterFrame);
    // The link may have been handled before the shell was built, and the
    // library loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _askForNewPassword();
      _announceReleases();
      _announceMilestones();
      _openLink();
      _offerOnboarding();
    });
  }

  @override
  void dispose() {
    _auth.removeListener(_askForNewPassword);
    _library.removeListener(_showNotices);
    _profile.removeListener(_showNotices);
    _lists.removeListener(_showNotices);
    _releases.removeListener(_announceReleases);
    _auth.removeListener(_openLinkAfterFrame);
    _links.removeListener(_openLinkAfterFrame);
    _milestones.removeListener(_announceMilestones);
    _onboarding.removeListener(_offerOnboardingAfterFrame);
    super.dispose();
  }

  /// A password reset link signed the user in: asks for the new password over
  /// whatever is open. Closing the screen without saving puts it off.
  Future<void> _askForNewPassword() async {
    if (!mounted || _askingForPassword || !_auth.isRecoveringPassword) return;
    _askingForPassword = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const NewPasswordScreen(afterReset: true),
      ),
    );
    _askingForPassword = false;
    _auth.dismissPasswordRecovery();
    _offerOnboardingAfterFrame();
  }

  /// After the frame: a sign-in screen that was open closes itself on the change
  /// that made the walk-through due, and must be gone before it opens.
  void _offerOnboardingAfterFrame() {
    if (!_onboarding.isDue) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerOnboarding());
  }

  /// Opens the first-run walk-through for a member whose library came back
  /// empty, once. Not over a password reset or a link the app was opened with:
  /// that is what the member came for. They are offered it at their next
  /// chance. Recorded as seen when it closes, finished or skipped.
  Future<void> _offerOnboarding() async {
    if (!mounted || _walkingThrough || _askingForPassword || _openingLink || _links.pending != null) return;
    final userId = _onboarding.takeOffer();
    if (userId == null) return;
    _walkingThrough = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const OnboardingScreen()),
    );
    _walkingThrough = false;
    unawaited(_onboarding.finish(userId));
  }

  /// Tells the user when an edit could not be saved (or was kept for later), from
  /// whichever screen they are on. (This used to be left in the store and only
  /// turned up as the Library tab's error screen.)
  void _showNotices() {
    _show(_library.notice, _library.clearNotice);
    _show(_profile.notice, _profile.clearNotice);
    _show(_lists.notice, _lists.clearNotice);
  }

  /// After the frame: a sign-in screen that was open for the link closes itself
  /// on the same change, and must be gone before the link's screen is pushed.
  void _openLinkAfterFrame() {
    if (_links.pending == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openLink());
  }

  /// Opens what the link the app was opened with points at. A game opens for
  /// anyone; a profile or a list needs a member, so sign-in is asked for first
  /// and the link opens once someone is signed in.
  Future<void> _openLink() async {
    final link = _links.pending;
    if (link == null || _openingLink || !mounted) return;
    if (link is! GameLink && !_auth.isLoggedIn) {
      if (!_askedToSignIn) {
        _askedToSignIn = true;
        unawaited(logIn(context));
      }
      return;
    }
    _openingLink = true;
    try {
      switch (link) {
        case GameLink(:final igdbId):
          final game = _library.maybeGame(gameIdForIgdb(igdbId)) ?? await _links.loadGame(igdbId);
          if (!mounted) return;
          if (game == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.linkGameNotFound)),
            );
          } else {
            openGame(context, game.id);
          }
        case MemberLink(:final userId):
          openProfile(context, userId: userId);
        case ListLink(:final listId):
          openList(context, listId);
      }
      _links.clear();
    } finally {
      _openingLink = false;
    }
  }

  /// Says once that wishlist games came out (see [ReleaseAlertsStore]).
  void _announceReleases() {
    final out = _releases.announce();
    if (out.isEmpty || !mounted) return;
    final game = out.first.game;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          out.length == 1
              ? context.l10n.wishlistGameOut(game.title)
              : context.l10n.wishlistGamesOut(out.length),
        ),
        action: out.length == 1
            ? SnackBarAction(label: context.l10n.open, onPressed: () => openGame(context, game.id))
            : null,
      ));
  }

  /// Celebrates milestones the server just awarded; those earned long ago (the
  /// first time this device sees the member's) are summed up instead.
  void _announceMilestones() {
    if (!mounted) return;
    final unlock = _milestones.takeAnnouncement();
    if (unlock == null) return;
    final earned = unlock.milestones;
    final count = earned.length;
    final l10n = context.l10n;
    final String message;
    if (unlock.fromHistory) {
      message = l10n.milestonesEarnedFromHistory(count);
    } else {
      final names = count == 1 ? earned.first.title : l10n.nameAndMore(earned.first.title, count - 1);
      final reward = earned.any((m) => m.frame != null)
          ? ' · ${l10n.newFrameUnlocked}'
          : earned.any((m) => m.rewardTitle != null)
          ? ' · ${l10n.newTitleUnlocked}'
          : '';
      message = l10n.milestoneUnlocked('$names$reward');
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: l10n.view,
          onPressed: () {
            final userId = _auth.user?.id;
            if (userId != null) openMilestones(context, userId: userId);
          },
        ),
      ));
  }

  void _show(String? message, VoidCallback clear) {
    if (message == null) return;
    clear();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final navIndex = context.watch<NavStore>().index;
    final isLoggedIn = context.watch<AuthStore>().isLoggedIn;
    return PopScope(
      canPop: navIndex == NavTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.read<NavStore>().select(NavTab.home);
      },
      child: Scaffold(
        body: IndexedStack(index: navIndex, children: _screens),
        floatingActionButton: navIndex == NavTab.home && isLoggedIn
            ? FloatingActionButton.extended(
                onPressed: () => showQuickLogSheet(context),
                icon: const Icon(Icons.add_rounded),
                label: Text(context.l10n.logGame),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navIndex,
          onDestinationSelected: (i) {
            FocusManager.instance.primaryFocus?.unfocus();
            context.read<NavStore>().select(i);
          },
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: context.l10n.navHome),
            NavigationDestination(icon: const Icon(Icons.search_rounded), selectedIcon: const Icon(Icons.search_rounded), label: context.l10n.navSearch),
            NavigationDestination(icon: const Icon(Icons.forum_outlined), selectedIcon: const Icon(Icons.forum_rounded), label: context.l10n.navDiscussions),
            NavigationDestination(icon: const Icon(Icons.collections_bookmark_outlined), selectedIcon: const Icon(Icons.collections_bookmark_rounded), label: context.l10n.navLibrary),
            NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: context.l10n.navProfile),
          ],
        ),
      ),
    );
  }
}
