import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/screens/profile/edit_profile_screen.dart';
import 'package:checkpoint/screens/settings/clear_library_panel.dart';
import 'package:checkpoint/screens/settings/connect_account.dart';
import 'package:checkpoint/screens/settings/delete_account_panel.dart';
import 'package:checkpoint/screens/settings/sync_library.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/connected_accounts_panel.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';
import 'package:checkpoint/widgets/profile_link_rows.dart';

/// Who is signed in, a way into Edit Profile, the accounts to connect (game
/// profiles and social media, with the library sync under the game profiles),
/// Sign out, and at the bottom clearing the library and the account deletion.
class AccountSection extends StatelessWidget {
  const AccountSection({super.key, required this.onDeletingChanged});

  /// Told when a deletion starts and when it ends without having worked.
  final ValueChanged<bool> onDeletingChanged;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final profileStore = context.watch<ProfileStore>();
    final profile = profileStore.profile;
    final email = auth.email;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Panel(
          title: context.l10n.signedInAs,
          child: Row(
            children: [
              ProfileAvatar(
                name: profile.name,
                size: 52,
                imageUrl: profile.avatarUrl,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      profile.handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (email != null)
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ProfileLinkRows(
          links: [
            ProfileLink(
              icon: Icons.edit_rounded,
              label: context.l10n.editProfile,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const EditProfileScreen(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ConnectedAccountsPanel(
          services: profileStore.connectedServices,
          names: profileStore.accountNames,
          editor: accountEditorFor(context),
          footer: profileStore.steamConnected
              ? const SyncLibraryButton()
              : null,
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await context.read<AuthStore>().logOut();
            // Signed out: nothing opened from the signed-in app belongs here any more.
            navigator.popUntil((route) => route.isFirst);
          },
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: Text(context.l10n.signOut),
        ),
        const SizedBox(height: 40),
        const ClearLibraryPanel(),
        const SizedBox(height: 14),
        DeleteAccountPanel(onDeletingChanged: onDeletingChanged),
      ],
    );
  }
}
