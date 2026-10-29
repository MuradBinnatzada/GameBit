import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException;

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/services/connection_failure.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';

/// Opens [NewPasswordScreen] to change the password of the signed-in email
/// account (Settings > Security).
Future<void> changePassword(BuildContext context) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => const NewPasswordScreen(),
  ),
);

/// Asks for a new password twice and saves it. With [afterReset] it is the
/// screen the app shell opens when a password reset link signed the user in:
/// "Choose a new password", which can be put off with Not now. Otherwise it is
/// Settings' Change password.
///
/// It closes once the password is saved, or when the account it was opened
/// for signs out (or another signs in); with [afterReset] also when the app
/// stops asking ([AuthStore.isRecoveringPassword]). A failed save says why in
/// a snack bar, worded by [AuthStore.messageFor].
class NewPasswordScreen extends StatefulWidget {
  const NewPasswordScreen({super.key, this.afterReset = false});

  final bool afterReset;

  @override
  State<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends State<NewPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final AuthStore _auth;
  late final String? _userId;

  bool _saving = false;
  bool _hidePassword = true;
  bool _closed = false;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthStore>();
    _userId = _auth.user?.id;
    _auth.addListener(_closeWhenNoLongerWanted);
  }

  @override
  void dispose() {
    _auth.removeListener(_closeWhenNoLongerWanted);
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _closeWhenNoLongerWanted() {
    final otherAccount = _auth.user?.id != _userId;
    if (otherAccount || (widget.afterReset && !_auth.isRecoveringPassword)) {
      _close();
    }
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) {
      setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    var saved = false;
    String message;
    try {
      await _auth.updatePassword(_password.text);
      saved = true;
      message = L10n.current.passwordChanged;
    } catch (e) {
      debugPrint('Changing the password failed: $e');
      // No live session yet (the app started offline) is a connection problem.
      message = _auth.messageFor(
        e is SessionPending ? AuthRetryableFetchException() : e,
      );
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    if (saved) {
      _close();
    } else if (mounted) {
      setState(() => _saving = false);
    }
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return context.l10n.signInChoosePassword;
    if (password.length < minPasswordLength) {
      return context.l10n.authWeakPasswordMinLength(minPasswordLength);
    }
    return null;
  }

  String? _validateConfirm(String? value) =>
      value != _password.text ? context.l10n.passwordsDontMatch : null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final account = context.watch<AuthStore>().email ?? l10n.yourAccount;
    final intro = widget.afterReset
        ? l10n.newPasswordAfterReset(account)
        : l10n.newPasswordIntro(account);

    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.afterReset ? l10n.chooseNewPassword : l10n.changePassword,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Form(
                  key: _formKey,
                  autovalidateMode: _autovalidate,
                  child: AutofillGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          intro,
                          style: TextStyle(
                            color: context.palette.muted,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _password,
                          enabled: !_saving,
                          obscureText: _hidePassword,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.newPassword],
                          decoration: InputDecoration(
                            labelText: l10n.newPassword,
                            suffixIcon: IconButton(
                              tooltip: _hidePassword
                                  ? l10n.showPassword
                                  : l10n.hidePassword,
                              icon: Icon(
                                _hidePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _hidePassword = !_hidePassword,
                              ),
                            ),
                          ),
                          validator: _validatePassword,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _confirm,
                          enabled: !_saving,
                          obscureText: _hidePassword,
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.newPassword],
                          decoration: InputDecoration(
                            labelText: l10n.confirmNewPassword,
                          ),
                          validator: _validateConfirm,
                          onFieldSubmitted: (_) => _save(),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10n.savePassword),
                        ),
                        if (widget.afterReset) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _saving ? null : _close,
                            child: Text(l10n.notNow),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
