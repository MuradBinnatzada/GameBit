/// The ranges the database accepts for what members type in
/// (20261019013500_value_limits_and_atomic_deletes.sql), and the tighter ones
/// the app asks for. The server checks its own; these keep a request it would
/// refuse from being sent.
library;

/// The most hours a game's total, or one session, can hold. The database's own
/// range, which a Steam sync can reach, so the store clamps to it and no lower.
const maxTotalHours = 100000.0;

/// The most hours a member can type in for a game's total or a session (Log
/// Hours, Edit session). Well under [maxTotalHours] so a slip like an extra zero
/// is refused: 20 000 hours is over 5 a day for 10 years in one game. A total
/// that is already past it (from Steam) can still be kept or lowered.
const maxManualHours = 20000.0;

/// The longest session the app logs at once: one sitting. A bigger change is
/// made to the game's total (Log Hours), which logs the difference.
const maxSessionHours = 24.0;

/// The shortest password the app asks for when one is chosen (sign-up, a reset,
/// Settings > Security > Change password). Supabase's own minimum is a setting of
/// the project (Authentication > Policies; `minimum_password_length` in
/// supabase/config.toml); the app asks for 8 whatever it is set to, so a project
/// left at the default of 6 doesn't let a short one in. Signing in accepts any
/// password: an older account may have a shorter one.
const minPasswordLength = 8;

/// The longest note on a play session.
const maxNoteLength = 1000;
