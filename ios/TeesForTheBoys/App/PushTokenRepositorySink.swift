import Foundation
import TeesData
import TeesPush

/// Bridges Track B's `PushTokenRepository` to Track E's `PushTokenSink` seam.
///
/// `ios/project.yml` keeps `TeesPush` down to one dependency (`TeesContract`)
/// on purpose — no Supabase in that module — and `TeesData` has no reason to
/// know `TeesPush` exists either. The app target is the only place allowed to
/// import both, per `AppSession`'s own doc comment, so this is where the two
/// sides meet.
///
/// Deliberately thin: `PushTokenRepository.register` returns the stored row
/// (useful to its own callers), where `PushTokenSink.register` only needs to
/// know it succeeded, and the two sides named the "forget this token" method
/// differently (`remove` vs. `retire`) because they were built independently
/// against the same idea. Nothing is renamed on either side.
struct PushTokenRepositorySink: PushTokenSink {
    let repository: PushTokenRepository

    func register(token: String, environment: TeesPush.PushEnvironment) async throws {
        _ = try await repository.register(token: token, environment: Self.dataEnvironment(for: environment))
    }

    func retire(token: String) async throws {
        try await repository.remove(token: token)
    }

    /// `TeesPush.PushEnvironment` and `TeesData.PushEnvironment` are the same
    /// two cases under the same name, because each track defined the concept
    /// independently rather than one depending on the other — exactly what
    /// this file's own header comment says `ios/project.yml` keeps apart on
    /// purpose. They are still nominally distinct types, so crossing the seam
    /// needs an explicit, exhaustive mapping rather than leaning on the two
    /// happening to share a name and raw values today.
    private static func dataEnvironment(for environment: TeesPush.PushEnvironment) -> TeesData.PushEnvironment {
        switch environment {
        case .sandbox: return .sandbox
        case .production: return .production
        }
    }
}
