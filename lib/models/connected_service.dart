import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Services the member can connect, each with its brand icon and color.
///
/// A service is only listed here when the app can prove the account belongs to
/// the member: Steam is connected by signing in through Steam, and the server
/// saves the Steam ID Steam confirms. A name the member could type in (a PSN
/// ID, a gamertag, a Discord or Instagram handle) proves nothing, lets anyone
/// claim someone else's account, and is not offered. Add a service here only
/// together with a sign-in the provider allows third parties to use.
enum ConnectedService {
  steam('Steam', FontAwesomeIcons.steam, Color(0xFF66C0F4));

  const ConnectedService(this.label, this.icon, this.color);
  final String label;
  final dynamic icon;
  final Color color;
}
