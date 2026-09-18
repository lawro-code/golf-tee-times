import SwiftUI

// Four states every screen in this track ends up in, written once.
//
// **These are deliberately unstyled.** Track D's token layer is being written
// concurrently, so anything beyond `TeesDesignModule.version` would not
// compile today. Every colour below is a SwiftUI semantic role and every font
// is a system text style, both of which already adapt to light/dark and
// Dynamic Type — so Stage 2 swaps D's tokens in by editing these modifiers,
// not by rewriting the views.
//
// Nothing here has a fixed height. At AX5 the message in an empty state is
// four or five lines tall, and a box sized for one line clips it.

/// A spinner and a sentence saying what is being waited on.
public struct ViewsLoadingState: View {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

/// Nothing to show, and — through `action` — something to do about it.
///
/// Generic over the action rather than taking a closure so a caller can put a
/// button, two buttons, or `EmptyView()` in there without this type growing an
/// opinion about any of them.
public struct ViewsEmptyState<Action: View>: View {
    private let title: String
    private let message: String
    private let action: Action

    public init(title: String, message: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Something broke. `retry` is optional because not everything that fails is
/// worth trying again, and a button that cannot help is worse than no button.
public struct ViewsErrorState: View {
    private let title: String
    private let message: String
    private let retry: (() -> Void)?

    public init(title: String, message: String, retry: (() -> Void)?) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Shown above the list when there is no connection.
///
/// It says what the golfer is looking at, not just that the network is down —
/// the tee times on screen are real, they are simply the last ones we managed
/// to fetch.
public struct ViewsOfflineBanner: View {
    public init() {}

    public var body: some View {
        ViewsBannerRow(
            systemImage: "wifi.slash",
            text: "You're offline. These are the last tee times we loaded.")
    }
}

/// Shown above the list when the data is old, a club could not be reached, or
/// both. Renders nothing at all when `summary.bannerText` is nil — the caller
/// can place it unconditionally.
public struct ViewsStaleBanner: View {
    private let summary: FreshnessSummary

    public init(summary: FreshnessSummary) {
        self.summary = summary
    }

    public var body: some View {
        if let text = summary.bannerText {
            ViewsBannerRow(systemImage: "exclamationmark.triangle", text: text)
        }
    }
}

/// The shared banner chrome. Not public: the two banners above are the vocabulary.
struct ViewsBannerRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
