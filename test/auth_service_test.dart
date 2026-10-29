import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AuthorizationErrorCode, SignInWithAppleAuthorizationException;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/services/auth_service.dart';

/// The user Supabase's `/signup` returns while email confirmation is required:
/// no session, and [identities] empty when the address already had an account.
Map<String, dynamic> _signUpUser({
  required List<Map<String, dynamic>> identities,
}) => {
  'id': 'e1abcdef-0000',
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': 'ada@example.com',
  'app_metadata': {
    'provider': 'email',
    'providers': ['email'],
  },
  'user_metadata': <String, dynamic>{},
  'identities': identities,
  'created_at': '2026-10-27T12:00:00Z',
};

final _emailIdentity = {
  'id': 'e1abcdef-0000',
  'user_id': 'e1abcdef-0000',
  'identity_id': 'i1',
  'identity_data': {'email': 'ada@example.com'},
  'provider': 'email',
};

void main() {
  late List<http.Request> requests;
  late Object? Function(http.Request) answer;
  late SupabaseClient client;
  late AuthService service;

  setUp(() {
    requests = [];
    answer = (_) => <String, dynamic>{};
    client = SupabaseClient(
      'http://localhost:54321',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(answer(request)),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      // The implicit flow needs no storage for a PKCE verifier.
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
    );
    service = AuthService(client);
  });

  tearDown(() async {
    await client.dispose();
  });

  group('signUpWithEmail', () {
    test('sends the trimmed address and the name for the profile', () async {
      answer = (_) => _signUpUser(identities: [_emailIdentity]);

      final signedIn = await service.signUpWithEmail(
        ' ada@example.com ',
        'correct horse',
        displayName: ' Ada Lovelace ',
      );

      expect(signedIn, isFalse); // waiting for the address to be confirmed
      expect(requests.single.url.path, '/auth/v1/signup');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['email'], 'ada@example.com');
      expect(body['password'], 'correct horse');
      expect(body['data'], {'full_name': 'Ada Lovelace'});
    });

    test('an address that already has an account is reported as one', () async {
      answer = (_) => _signUpUser(identities: []);

      await expectLater(
        service.signUpWithEmail('ada@example.com', 'correct horse'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.code,
            'code',
            'user_already_exists',
          ),
        ),
      );
    });
  });

  test(
    'sendPasswordReset asks Supabase to email the trimmed address',
    () async {
      await service.sendPasswordReset(' ada@example.com ');

      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/auth/v1/recover');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['email'], 'ada@example.com');
    },
  );

  test('signInWithEmail signs in with the trimmed address', () async {
    answer = (_) => {
      'access_token': 'a',
      'refresh_token': 'r',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': _signUpUser(identities: [_emailIdentity]),
    };

    await service.signInWithEmail(' ada@example.com ', 'correct horse');

    expect(requests.single.url.path, '/auth/v1/token');
    expect(requests.single.url.queryParameters['grant_type'], 'password');
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['email'], 'ada@example.com');
    expect(service.currentUser?.email, 'ada@example.com');
  });

  test(
    'updatePassword saves the new password of the signed-in account',
    () async {
      final session = {
        'access_token': 'a',
        'refresh_token': 'r',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': _signUpUser(identities: [_emailIdentity]),
      };
      answer = (request) => request.url.path == '/auth/v1/user'
          ? _signUpUser(identities: [_emailIdentity])
          : session;
      await service.signInWithEmail('ada@example.com', 'old password');
      requests.clear();

      await service.updatePassword('correct horse');

      expect(requests.single.method, 'PUT');
      expect(requests.single.url.path, '/auth/v1/user');
      expect(requests.single.headers['authorization'], 'Bearer a');
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body, {'password': 'correct horse'});
    },
  );

  test('appleFullName joins the parts Apple shared, and is null without any', () {
    expect(AuthService.appleFullName(' Ada ', 'Lovelace'), 'Ada Lovelace');
    expect(AuthService.appleFullName('Ada', null), 'Ada');
    expect(AuthService.appleFullName(null, ' '), isNull);
    expect(AuthService.appleFullName(null, null), isNull);
  });

  group('messageFor', () {
    String message(String code, [String text = 'raw']) =>
        AuthService.messageFor(
          AuthApiException(text, statusCode: '400', code: code),
        );

    test('says a suspended account was suspended, and where to write', () {
      expect(
        message('user_banned', 'User is banned'),
        'This account has been suspended for breaking the community rules. If you think this is a mistake, write to muradbinnetzade14@gmail.com.',
      );
    });

    test('words the email sign-in failures for people', () {
      expect(
        message('invalid_credentials'),
        startsWith('Wrong email or password.'),
      );
      expect(
        message('user_already_exists'),
        startsWith('That email is already registered.'),
      );
      expect(
        message('email_exists'),
        startsWith('That email is already registered.'),
      );
      expect(
        message('email_not_confirmed'),
        startsWith('Confirm your email first'),
      );
      expect(
        AuthService.messageFor(
          AuthWeakPasswordException(
            message: 'Password should be at least 8 characters.',
            statusCode: '422',
            reasons: ['length'],
          ),
        ),
        'That password is too weak. Password should be at least 8 characters.',
      );
    });

    test('words a refused password change', () {
      expect(
        message('same_password'),
        'That is your current password. Choose a different one.',
      );
      expect(
        message('reauthentication_needed'),
        startsWith('For your security, sign out and sign in again'),
      );
    });

    test('words Apple sign-in failures', () {
      expect(
        AuthService.messageFor(
          const SignInWithAppleAuthorizationException(
            code: AuthorizationErrorCode.canceled,
            message: 'The user canceled the authorization attempt.',
          ),
        ),
        'Apple sign-in was cancelled.',
      );
      expect(
        AuthService.messageFor(
          const SignInWithAppleAuthorizationException(
            code: AuthorizationErrorCode.failed,
            message: 'raw',
          ),
        ),
        'Apple sign-in failed. Please try again.',
      );
    });

    test('says when Supabase could not be reached', () {
      expect(
        AuthService.messageFor(
          AuthRetryableFetchException(message: 'Failed host lookup'),
        ),
        "Can't reach Checkpoint. Check your connection and try again.",
      );
    });

    test('passes other messages through, as the Google flow relies on', () {
      expect(
        AuthService.messageFor(AuthException('Google sign-in was cancelled.')),
        'Google sign-in was cancelled.',
      );
      expect(
        message('something_new', 'Something new happened'),
        'Something new happened',
      );
    });
  });
}
