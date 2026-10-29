import 'package:supabase_flutter/supabase_flutter.dart';

/// The database refuses public text that has a word the chat rules refuse
/// (reviews, bios, names, handles, list titles; the same filter as the
/// discussions, see 20261028235500_moderation_and_blocking.sql) with SQLSTATE
/// `CP422`. The text is not saved, and sending it again changes nothing.
const contentRefusedCode = 'CP422';

/// Whether [error] is the server refusing text that breaks the chat rules.
bool isContentRefusal(Object error) =>
    error is PostgrestException && error.code == contentRefusedCode;

/// The table's column the refused text was for (`bio`, `review`, `title`...), when known.
String? refusedField(Object error) =>
    isContentRefusal(error) ? (error as PostgrestException).details?.toString() : null;

/// SQLSTATE the database raises when a member reports too fast.
const rateLimitedCode = 'CP429';

/// Whether [error] is the server saying a member did that too often lately.
bool isRateLimited(Object error) =>
    error is PostgrestException && error.code == rateLimitedCode;
