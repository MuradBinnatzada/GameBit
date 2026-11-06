import 'package:flutter/foundation.dart';

/// The two letters of the device's region ("DE"), "US" when it has none: what picks
/// the currency of prices and of the notifications about them.
String deviceCountry({String? override}) {
  final code = override ?? PlatformDispatcher.instance.locale.countryCode;
  return code != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(code) ? code.toUpperCase() : 'US';
}
