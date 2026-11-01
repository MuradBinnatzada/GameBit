import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/services/auth_service.dart';

/// What Google's native client hands back: an account with ID and access tokens.
class _FakeAuthentication implements GoogleSignInAuthentication {
  @override
  String? get idToken => 'google-id-token';

  @override
  String? get accessToken => 'google-access-token';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAccount implements GoogleSignInAccount {
  @override
  Future<GoogleSignInAuthentication> get authentication async =>
      _FakeAuthentication();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Google's native client, which remembers the account it last signed in: while
/// it does, [signIn] answers it again without a picker ([remembered]), like the
/// real one. [calls] is what was asked, in order.
class _FakeGoogle implements GoogleSignIn {
  final List<String> calls = [];
  GoogleSignInAccount? remembered;

  /// What the picker answers when it is shown (null: the member backed out).
  GoogleSignInAccount? chosen = _FakeAccount();

  /// How many times the picker was shown.
  int pickers = 0;

  @override
  Future<GoogleSignInAccount?> signIn() async {
    calls.add('signIn');
    if (remembered != null) return remembered;
    pickers++;
    return remembered = chosen;
  }

  @override
  Future<GoogleSignInAccount?> signOut() async {
    calls.add('signOut');
    remembered = null;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A session as Supabase's `/token` answers it, with a token that only says when
/// it expires.
Map<String, dynamic> _session() {
  String part(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final token = [
    part({'alg': 'HS256', 'typ': 'JWT'}),
    part({
      'sub': 'u1',
      'aud': 'authenticated',
      'exp': 4102444800, // 2100
    }),
    'signature',
  ].join('.');
  return {
    'access_token': token,
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh',
    'user': {
      'id': 'u1',
      'aud': 'authenticated',
      'role': 'authenticated',
      'email': 'ada@example.com',
      'app_metadata': {
        'provider': 'google',
        'providers': ['google'],
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2026-10-27T12:00:00Z',
    },
  };
}

/// Google sign-in on a phone: the native account picker, then Supabase. A
/// suspended account is refused by Supabase, and the next try has to offer the
/// picker again.
void main() {
  late _FakeGoogle google;
  late SupabaseClient client;
  late AuthService service;
  late int status;
  late Map<String, dynamic> body;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    google = _FakeGoogle();
    status = 200;
    body = _session();
    client = SupabaseClient(
      'http://localhost:54321',
      'anon-key',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode(body),
          status,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      ),
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );
    service = AuthService(client, googleSignIn: google);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await client.dispose();
  });

  void suspended() {
    status = 400;
    body = {
      'code': 400,
      'error_code': 'user_banned',
      'msg': 'User is banned',
    };
  }

  test('a sign-in that works leaves Google signed in', () async {
    await service.signInWithGoogle();

    expect(client.auth.currentUser?.id, 'u1');
    expect(google.calls, ['signOut', 'signIn']);
    expect(google.remembered, isNotNull);
  });

  test('a suspended account is refused, and Google forgets it', () async {
    suspended();

    await expectLater(
      service.signInWithGoogle(),
      throwsA(
        isA<AuthException>().having((e) => e.code, 'code', 'user_banned'),
      ),
    );

    expect(client.auth.currentUser, isNull);
    expect(google.remembered, isNull);
    expect(google.calls, ['signOut', 'signIn', 'signOut']);
  });

  test('so the next try shows the picker, and another account gets in', () async {
    suspended();
    await expectLater(service.signInWithGoogle(), throwsA(isA<AuthException>()));
    expect(google.pickers, 1);

    // The member picks another account this time, and Supabase accepts it.
    status = 200;
    body = _session();
    await service.signInWithGoogle();

    expect(google.pickers, 2);
    expect(client.auth.currentUser?.id, 'u1');
  });

  test('the picker is shown even when Google remembers an earlier account', () async {
    google.remembered = _FakeAccount();

    await service.signInWithGoogle();

    expect(google.pickers, 1);
  });

  test('backing out of the picker is not a sign-in, and not an error to remember', () async {
    google.chosen = null;

    await expectLater(
      service.signInWithGoogle(),
      throwsA(
        isA<AuthException>().having(
          (e) => e.message,
          'message',
          'Google sign-in was cancelled.',
        ),
      ),
    );

    expect(google.calls, ['signOut', 'signIn']);
  });

  test('signing out forgets the Google account too', () async {
    await service.signInWithGoogle();
    google.calls.clear();

    await service.signOut();

    expect(google.calls, ['signOut']);
    expect(google.remembered, isNull);
  });
}
