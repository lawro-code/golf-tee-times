import Foundation

/// Track B — the data layer. Supabase, auth, fetch, decode, cache. No SwiftUI.
///
/// ## What lives here, and who wires it
///
/// This module ships parts, not a composition root. Stage 2 wires them together
/// in the app target; the only assembled thing the track exports is
/// `TeeTimeStore.live` (B3), which is the store a screen actually holds.
///
/// | Type | What it is for | Built by |
/// |---|---|---|
/// | `DataError` | The one error type every file in this track throws. Track C branches on it. | everywhere |
/// | `DataLog` | `os.Logger` wrapper. `DataLog.dropped` is where a dropped malformed row states its reason. | everywhere |
/// | `SupabaseConfiguration` | Resolves the project URL and anon key. No key is committed to this repo. | the host app at launch, or the environment |
/// | `SupabaseClientProvider` | One lazily-built shared `SupabaseClient`, and an injectable one for tests. | Stage 2, once |
/// | `KeychainSessionStorage` | Where the Supabase session is persisted between launches. `InMemorySessionStorage` is its test/preview twin. | `SupabaseClientProvider` |
/// | `AuthService` | Sign-up, sign-in, sign-out, restore-on-launch, and the `SessionProviding` seam. | Stage 2, once |
/// | `SlotsFetching` / `PayloadCaching` / `SessionProviding` | The seams the rest of the track implements and consumes. | B2 (remote), B3 (cache + store), B4 (user data) |
///
/// ## The rule that shapes the whole track
///
/// **Browsing works signed out.** Nothing on the read path may require a user.
/// `SessionProviding.requireUserID()` exists so that alerts, watches and
/// bookings — and only those — fail loudly when nobody is signed in.
///
/// ## Two things that are deliberately absent
///
/// - No SwiftUI import anywhere in this directory. The compiler enforces the
///   module boundary; this is the house rule that keeps it honest.
/// - No hand-rolled JWT refresh. `autoRefreshToken` is on and the SDK refreshes
///   before expiry. This track owns persistence and restore, not token maths.
public enum TeesDataModule {
    public static let version = "1.0.0"
}
