import SwiftUI
import TeesContract
import TeesDesign

/// The six things a golfer narrows by, as one horizontally scrolling row of
/// chips across the top of the results.
///
/// It is a chip row rather than a form because the results behind it update as
/// the chips move — there is no Apply button anywhere in this screen. A chip
/// carries its own current value, so the state of the search is readable
/// without opening anything: `Sat 19 Sep · Morning · 4 players · 18 holes`.
///
/// Every chip is a button with the `.isSelected` trait and an
/// `accessibilityValue`, which is what makes the row usable without looking at
/// it — VoiceOver reads "Price, under $60, selected, button" rather than six
/// identical "button"s.
public struct FilterBar: View {
    @ObservedObject private var store: SearchStore

    /// Which chip's sheet is up. `nil` is "none", which is what lets
    /// `.sheet(item:)` do the presenting instead of a pile of booleans.
    @State private var presented: FilterField?

    public init(store: SearchStore) {
        self.store = store
    }

    public var body: some View {
        // Read once. `filters` is a stored published value, but pulling it into
        // a local keeps every chip in one pass agreeing on the same snapshot.
        let filters = store.filters
        let today = store.today

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SearchStyle.chipSpacing) {
                if filters.activeCount > 0 {
                    clearButton
                }

                ForEach(FilterField.allCases) { field in
                    FilterChip(
                        title: field.chipTitle(filters: filters, today: today),
                        isSelected: field.isSelected(in: filters),
                        spokenValue: field.spokenValue(filters: filters, today: today),
                        name: field.name
                    ) {
                        presented = field
                    }
                }
            }
            .padding(.horizontal, SearchStyle.gutter)
            .padding(.vertical, SearchStyle.chipSpacing)
        }
        .sheet(item: $presented) { field in
            FilterSheet(store: store, field: field)
        }
    }

    /// Only ever on screen when there is something to clear. A permanently
    /// visible Clear on an unfiltered search is a control that does nothing.
    ///
    /// Internal rather than `private`: `FilterBarLayoutTests` measures its
    /// real, un-mocked tap target height and needs to reach it directly.
    var clearButton: some View {
        Button {
            store.resetFilters()
        } label: {
            Label("Clear", systemImage: "xmark")
                .labelStyle(.titleOnly)
                .searchChipText()
                .padding(.horizontal, SearchStyle.chipPadding)
                .padding(.vertical, SearchStyle.chipPadding * 0.6)
                .frame(minHeight: TeesLayout.minTapTarget)
                .background(SearchStyle.chipBackground(isSelected: false), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear filters")
        .accessibilityHint("Back to one player, 18 holes, every day")
    }
}

// MARK: - One chip

/// A capsule that states its own value.
///
/// Not public: `FilterBar` is the vocabulary, and a loose chip with no sheet
/// behind it would be a control that looks live and is not.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let spokenValue: String
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .searchChipText()
                .lineLimit(1)
                .padding(.horizontal, SearchStyle.chipPadding)
                .padding(.vertical, SearchStyle.chipPadding * 0.6)
                .frame(minHeight: TeesLayout.minTapTarget)
                .background(SearchStyle.chipBackground(isSelected: isSelected), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        SearchStyle.chipBorder(isSelected: isSelected),
                        lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The chip's visible text is its value, not its name, so the two are
        // separated for VoiceOver: label is what it filters, value is what it
        // is set to.
        .accessibilityLabel(name)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens \(name) options")
    }
}

// MARK: - The six fields

/// Which filter a chip and its sheet are about.
///
/// The chip's title, its selected state and its spoken value are pure
/// functions of `SearchFilters` and live here rather than inside the view, so
/// "picking three days makes the chip read 3 days" is a test rather than a
/// screenshot.
public enum FilterField: String, CaseIterable, Identifiable, Sendable {
    case day
    case time
    case players
    case holes
    case price
    case drive

    public var id: String { rawValue }

    /// What the filter is called when it has no value to show.
    public var name: String {
        switch self {
        case .day: return "Day"
        case .time: return "Time"
        case .players: return "Players"
        case .holes: return "Holes"
        case .price: return "Price"
        case .drive: return "Drive"
        }
    }

    /// The chip's visible text: its current value when set, its name when not.
    ///
    /// Holes is the exception, and deliberately: it defaults to 18 rather than
    /// to nothing (CONTRACT.md §2 — three 18-hole clubs sell 9-hole rounds), so
    /// the chip always states a number. A golfer on a first run has to be able
    /// to see that 18 is already chosen for them.
    public func chipTitle(filters: SearchFilters, today: String) -> String {
        switch self {
        case .day:
            guard let first = filters.days.sorted().first else { return name }
            if filters.days.count == 1 {
                return SlotFormatting.dayTitle(for: first, today: today)
            }
            return "\(filters.days.count) days"

        case .time:
            guard filters.timesOfDay.count != 1 else {
                return filters.timesOfDay.first?.title ?? name
            }
            return filters.timesOfDay.isEmpty ? name : "\(filters.timesOfDay.count) times"

        case .players:
            return filters.players > 1 ? "\(filters.players) players" : name

        case .holes:
            return filters.holes.title

        case .price:
            guard let ceiling = filters.maxPrice else { return name }
            return "Under \(SlotFormatting.money(ceiling))"

        case .drive:
            guard let minutes = filters.maxDriveMinutes else { return name }
            return "Under \(minutes) min"
        }
    }

    /// Whether the chip reads as active.
    ///
    /// 18 holes is the documented default, so it does not light up — same rule
    /// as `SearchFilters.activeCount`, and the two must agree or the badge says
    /// one filter while no chip looks set.
    public func isSelected(in filters: SearchFilters) -> Bool {
        switch self {
        case .day: return !filters.days.isEmpty
        case .time: return !filters.timesOfDay.isEmpty
        case .players: return filters.players > 1
        case .holes: return filters.holes != .eighteen
        case .price: return filters.maxPrice != nil
        case .drive: return filters.maxDriveMinutes != nil
        }
    }

    /// The `accessibilityValue`. Says "any" rather than staying silent: an
    /// unset filter is a fact about the search, not an absence of one.
    public func spokenValue(filters: SearchFilters, today: String) -> String {
        switch self {
        case .day:
            if filters.days.isEmpty { return "Any day" }
            if filters.days.count == 1, let only = filters.days.first {
                return SlotFormatting.spokenDayTitle(for: only)
            }
            return "\(filters.days.count) days selected"

        case .time:
            if filters.timesOfDay.isEmpty { return "Any time" }
            let ordered = SearchFilters.TimeOfDay.allCases.filter { filters.timesOfDay.contains($0) }
            return ordered.map(\.title).joined(separator: ", ")

        case .players:
            return filters.players == 1 ? "1 player" : "\(filters.players) players"

        case .holes:
            return filters.holes.title

        case .price:
            guard let ceiling = filters.maxPrice else { return "Any price" }
            return "Under \(SlotFormatting.money(ceiling))"

        case .drive:
            guard let minutes = filters.maxDriveMinutes else { return "Any drive" }
            return "Under \(minutes) minutes from Bondi"
        }
    }
}

#if DEBUG
#Preview("Filter bar") {
    FilterBar(store: SearchStore.previewStore())
}
#endif
