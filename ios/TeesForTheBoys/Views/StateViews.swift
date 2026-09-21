import SwiftUI
import TeesDesign

// Four states every screen in this track ends up in, written once.
//
// Every colour below is a `TeesColor` semantic role and every font a
// `TeesFont` role — `docs/style.css`'s `.loading`/`.empty` are italic serif,
// muted, centred, which is what `ViewsLoadingState` and `ViewsErrorState`
// port here.
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
        VStack(spacing: TeesSpacing.md) {
            ProgressView()
                .tint(TeesColor.green)
            Text(message)
                .font(TeesFont.quote)
                .foregroundStyle(TeesColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(TeesSpacing.xxl)
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
        VStack(spacing: TeesSpacing.md) {
            Text(title)
                .font(TeesFont.bodyStrong)
                .foregroundStyle(TeesColor.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(TeesFont.quote)
                .foregroundStyle(TeesColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(TeesSpacing.xxl)
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
        VStack(spacing: TeesSpacing.md) {
            Text(title)
                .font(TeesFont.bodyStrong)
                .foregroundStyle(TeesColor.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(TeesFont.quote)
                .foregroundStyle(TeesColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.teesSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(TeesSpacing.xxl)
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
        HStack(alignment: .firstTextBaseline, spacing: TeesSpacing.sm) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .font(TeesFont.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(TeesColor.muted)
        .padding(.horizontal, TeesSpacing.lg)
        .padding(.vertical, TeesSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TeesColor.gold.opacity(0.14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
