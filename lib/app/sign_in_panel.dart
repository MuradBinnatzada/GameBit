import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/legal_links.dart';

enum _Mode { signIn, signUp }

/// What a sign-in or sign-up is waiting on, to show its button as busy.
enum _Pending { google, apple, email, reset }

/// The longest display name the profile editor accepts.
const _nameMax = 40;

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// The ways to sign in: Google, Apple (on iOS), or an email address and password (sign in,
/// create an account, or have a reset link sent), under a [title] and
/// [message] saying what signing in is for.
///
/// A failed attempt says why in a snack bar, worded by [AuthStore.messageFor];
/// what to do next after an email was sent stays on the panel.
class SignInPanel extends StatefulWidget {
  const SignInPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  State<SignInPanel> createState() => _SignInPanelState();
}

class _SignInPanelState extends State<SignInPanel> {
  final _formKey = GlobalKey<FormState>();
  final _emailKey = GlobalKey<FormFieldState<String>>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  _Mode _mode = _Mode.signIn;
  _Pending? _pending;
  bool _hidePassword = true;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  /// What to do after an email went out (confirm the address, reset the password).
  String? _notice;

  bool get _busy => _pending != null;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Runs [action] with the buttons disabled and, when it fails, says why.
  Future<void> _run(
    _Pending pending,
    Future<void> Function(AuthStore auth) action,
  ) async {
    final auth = context.read<AuthStore>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _pending = pending;
      _notice = null;
    });
    try {
      await action(auth);
    } catch (e) {
      debugPrint('Sign-in failed: $e');
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(auth.messageFor(e))));
    } finally {
      // A sign-in that worked usually takes this panel away with it.
      if (mounted) setState(() => _pending = null);
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_busy) return;
    await _run(_Pending.google, (auth) => auth.signInWithGoogle());
  }

  Future<void> _signInWithApple() async {
    if (_busy) return;
    await _run(_Pending.apple, (auth) => auth.signInWithApple());
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) {
      setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
      return;
    }
    final email = _email.text.trim();
    final password = _password.text;
    if (_mode == _Mode.signIn) {
      await _run(
        _Pending.email,
        (auth) => auth.signInWithEmail(email, password),
      );
      return;
    }
    await _run(_Pending.email, (auth) async {
      final signedIn = await auth.signUpWithEmail(
        email,
        password,
        displayName: _name.text.trim(),
      );
      if (signedIn || !mounted) return;
      // The project wants the address confirmed before the first sign-in.
      setState(() {
        _mode = _Mode.signIn;
        _password.clear();
        _notice = context.l10n.signInConfirmationSent(email);
      });
    });
  }

  Future<void> _sendPasswordReset() async {
    if (_busy) return;
    // Only the address is needed, so only its field is checked (and the
    // form isn't set to recheck the others as they change).
    if (!_emailKey.currentState!.validate()) return;
    final email = _email.text.trim();
    await _run(_Pending.reset, (auth) async {
      await auth.sendPasswordReset(email);
      if (!mounted) return;
      setState(
        () => _notice = context.l10n.signInResetSent(email),
      );
    });
  }

  void _setMode(_Mode mode) => setState(() {
    _mode = mode;
    _notice = null;
  });

  String? _validateName(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return context.l10n.signInNameRequired;
    if (text.length > _nameMax) return context.l10n.maxCharacters(_nameMax);
    return null;
  }

  String? _validateEmail(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return context.l10n.signInEmailRequired;
    if (!_emailPattern.hasMatch(text)) return context.l10n.signInEmailInvalid;
    return null;
  }

  String? _validatePassword(String? value) {
    if ((value ?? '').isEmpty) {
      return _mode == _Mode.signIn
          ? context.l10n.signInPasswordRequired
          : context.l10n.signInChoosePassword;
    }
    if (_mode == _Mode.signUp && value!.length < minPasswordLength) {
      return context.l10n.authWeakPasswordMinLength(minPasswordLength);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final signingUp = _mode == _Mode.signUp;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: context.palette.surfaceHigh,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, color: context.palette.accent, size: 32),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.message,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.muted, height: 1.35),
              ),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _signInWithGoogle,
                icon: _pending == _Pending.google
                    ? const _Spinner()
                    : const FaIcon(FontAwesomeIcons.google, size: 16),
                label: Text(context.l10n.continueWithGoogle),
              ),
              if (context.read<AuthStore>().offersAppleSignIn) ...[
                const SizedBox(height: 10),
                // Apple's guidelines: as prominent as the other providers, with
                // its logo and "Continue with Apple".
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _signInWithApple,
                  icon: _pending == _Pending.apple
                      ? const _Spinner()
                      : const FaIcon(FontAwesomeIcons.apple, size: 18),
                  label: Text(context.l10n.continueWithApple),
                ),
              ],
              const SizedBox(height: 20),
              // With large text the words wrap, leaving the lines a little room.
              LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    const Expanded(child: Divider()),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: constraints.maxWidth - 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          context.l10n.signInOrUseEmail,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.palette.muted, fontSize: 13),
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<_Mode>(
                segments: [
                  ButtonSegment(value: _Mode.signIn, label: Text(context.l10n.signIn)),
                  ButtonSegment(
                    value: _Mode.signUp,
                    label: Text(context.l10n.createAccount),
                  ),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: _busy
                    ? null
                    : (selected) => _setMode(selected.single),
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                autovalidateMode: _autovalidate,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (signingUp) ...[
                        TextFormField(
                          key: const ValueKey('sign-in-name'),
                          controller: _name,
                          enabled: !_busy,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.name],
                          maxLength: _nameMax,
                          decoration: InputDecoration(
                            labelText: context.l10n.displayName,
                            helperText: context.l10n.signInDisplayNameHelper,
                            counterText: '',
                          ),
                          validator: _validateName,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        key: _emailKey,
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const [AutofillHints.email],
                        decoration: InputDecoration(labelText: context.l10n.email),
                        validator: _validateEmail,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const ValueKey('sign-in-password'),
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _hidePassword,
                        textInputAction: TextInputAction.done,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: [
                          signingUp
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        decoration: InputDecoration(
                          labelText: context.l10n.password,
                          suffixIcon: IconButton(
                            tooltip: _hidePassword
                                ? context.l10n.showPassword
                                : context.l10n.hidePassword,
                            icon: Icon(
                              _hidePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _hidePassword = !_hidePassword),
                          ),
                        ),
                        validator: _validatePassword,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                    ],
                  ),
                ),
              ),
              if (!signingUp)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: _busy ? null : _sendPasswordReset,
                    child: _pending == _Pending.reset
                        ? const _Spinner()
                        : Text(context.l10n.forgotPassword),
                  ),
                )
              else
                const SizedBox(height: 16),
              const SizedBox(height: 4),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _pending == _Pending.email
                    ? const _Spinner()
                    : Text(signingUp ? context.l10n.createAccount : context.l10n.signIn),
              ),
              if (_notice case final notice?) ...[
                const SizedBox(height: 16),
                _Notice(notice),
              ],
              const SizedBox(height: 20),
              const SignInAgreement(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opened by the "Log in" buttons outside an [AuthGate]'s overlay (see
/// `logIn`), and closed again as soon as someone is signed in.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final AuthStore _auth;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthStore>();
    _auth.addListener(_closeOnceSignedIn);
  }

  @override
  void dispose() {
    _auth.removeListener(_closeOnceSignedIn);
    super.dispose();
  }

  void _closeOnceSignedIn() {
    if (_closed || !mounted || !_auth.isLoggedIn) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.logIn)),
      body: SafeArea(
        child: SignInPanel(
          icon: Icons.lock_outline_rounded,
          title: context.l10n.logInToCheckpoint,
          message: context.l10n.logInMessage,
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.palette.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.mark_email_read_outlined,
              color: context.palette.accent,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
          ],
        ),
      ),
    );
  }
}
