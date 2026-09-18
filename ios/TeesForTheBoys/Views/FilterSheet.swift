import SwiftUI
import TeesContract

/// The sheet behind one filter chip.
///
/// Every control in here writes straight back to `store.filters` as it moves.
/// There is no Apply button and no draft copy of the filters, which is the
/// whole point: the count in the footer and the list behind the sheet both
/// update while a thumb is still on the slider, so the effect of a choice is
/// visible before it is committed to.
///
/// The sheet is detented rather than full-screen for the same reason — a
/// golfer needs to see the list moving underneath.
public struct FilterSheet: View {
    @ObservedObject private var store: SearchStore
    private let field: FilterField

    @Environment(\.dismiss) private var dismiss

    /// The slider ends, resolved once when the sheet appears rather than on
    /// every body pass. Deriving them is O(slots) and the body runs on every
    /// tick of a drag; `@State` survives the re-inits `.sheet(item:)` causes,
    /// so the work happens once per presentation.
    @State private var bounds: FilterBounds = .fallback

    public init(store: SearchStore, field: FilterField) {
        self.store = store
        self.field = field
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SearchStyle.sectionSpacing) {
                    switch field {
                    case .day: daySection
                    case .time: timeSection
                    case .players: playersSection
                    case .holes: holesSection
                    case .price: priceSection
                    case .drive: driveSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SearchStyle.gutter)
            }
            .navigationTitle(field.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            bounds = FilterBounds.make(slots: store.payload?.slots ?? [], courses: store.courses)
        }
    }

    // MARK: - Footer

    /// The live count. It is the sheet's only summary of what the controls
    /// above have done, and it moves while they move.
    private var footer: some View {
        Button {
            dismiss()
        } label: {
            Text(Self.footerTitle(resultCount: store.resultCount))
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Deliberately still tappable at zero. Dismissing onto the empty state
        // is the right outcome — that screen's primary action is the alert,
        // which is exactly what a search matching nothing needs next.
        .padding(SearchStyle.gutter)
        .background(.bar)
    }

    /// Pure, so the plural and the zero case are asserted rather than eyeballed.
    static func footerTitle(resultCount: Int) -> String {
        switch resultCount {
        case 0: return "No tee times match"
        case 1: return "Show 1 tee time"
        default: return "Show \(resultCount) tee times"
        }
    }

    // MARK: - Day

    /// Only the days the payload actually has. Offering a seventh day the
    /// scrape never covered is offering an empty list.
    ///
    /// O(slots) once per body pass, not once per row — the expensive thing in
    /// this track is doing work inside a `ForEach`, and this is outside one.
    private var availableDays: [String] {
        guard let payload = store.payload else { return [] }
        return Array(Set(payload.slots.map(\.teeDate))).sorted()
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            sectionHint("No day chosen means every day we have.")

            ForEach(availableDays, id: \.self) { date in
                FilterOptionRow(
                    title: SlotFormatting.dayTitle(for: date, today: store.today),
                    subtitle: SlotFormatting.spokenDayTitle(for: date),
                    isSelected: store.filters.days.contains(date)
                ) {
                    store.filters = FilterMutation.toggling(day: date, in: store.filters)
                }
            }
        }
    }

    // MARK: - Time of day

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            sectionHint("No time chosen means any time of day.")

            ForEach(SearchFilters.TimeOfDay.allCases, id: \.self) { slot in
                FilterOptionRow(
                    title: slot.title,
                    subtitle: slot.subtitle,
                    isSelected: store.filters.timesOfDay.contains(slot)
                ) {
                    store.filters = FilterMutation.toggling(time: slot, in: store.filters)
                }
            }
        }
    }

    // MARK: - Players

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            sectionHint("Only shows tee times with at least this many spots free.")

            FilterOptionGroup(
                options: FilterMutation.playerOptions,
                label: { $0 == 1 ? "1 player" : "\($0) players" },
                isSelected: { $0 == store.filters.players },
                select: { store.filters = FilterMutation.setting(players: $0, in: store.filters) })
        }
    }

    // MARK: - Holes

    private var holesSection: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            // CONTRACT.md §2. Bankstown, Beverley Park and Brighton Lakes are
            // 18-hole clubs that also sell 9-hole rounds, so this is a real
            // choice and 18 is a real default rather than an absence of one.
            sectionHint("Some 18-hole clubs also sell 9-hole rounds, so this is the booking's hole count, not the course's.")

            FilterOptionGroup(
                options: SearchFilters.HolesFilter.allCases,
                label: { $0.title },
                isSelected: { $0 == store.filters.holes },
                select: { store.filters = FilterMutation.setting(holes: $0, in: store.filters) })
        }
    }

    // MARK: - Price

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            Text(FilterMutation.priceLabel(store.filters.maxPrice))
                .searchTitleText()

            Slider(
                value: priceBinding(bounds: bounds),
                in: bounds.minPrice...bounds.maxPrice,
                step: FilterBounds.priceStep
            ) {
                Text("Maximum price")
            } minimumValueLabel: {
                Text(SlotFormatting.money(bounds.minPrice)).searchCaptionText()
            } maximumValueLabel: {
                Text("Any").searchCaptionText()
            }
            .accessibilityValue(FilterMutation.priceLabel(store.filters.maxPrice))

            // CONTRACT.md §3, said out loud where the decision is made. 282 of
            // the golden fixture's 1755 slots publish no fee; a golfer sliding
            // this down has to know they are not being hidden.
            sectionHint("Tee times with no published price are always shown, labelled \u{201C}\(SlotFormatting.priceAtCourse)\u{201D}.")
        }
    }

    private func priceBinding(bounds: FilterBounds) -> Binding<Double> {
        Binding(
            get: { store.filters.maxPrice ?? bounds.maxPrice },
            set: { store.filters = FilterMutation.setting(maxPrice: $0, ceiling: bounds.maxPrice, in: store.filters) })
    }

    // MARK: - Drive

    private var driveSection: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            Text(FilterMutation.driveLabel(store.filters.maxDriveMinutes))
                .searchTitleText()

            Slider(
                value: driveBinding(bounds: bounds),
                in: Double(bounds.minDriveMinutes)...Double(bounds.maxDriveMinutes),
                step: Double(FilterBounds.driveStep)
            ) {
                Text("Maximum drive")
            } minimumValueLabel: {
                Text("\(bounds.minDriveMinutes)m").searchCaptionText()
            } maximumValueLabel: {
                Text("Any").searchCaptionText()
            }
            .accessibilityValue(FilterMutation.driveLabel(store.filters.maxDriveMinutes))

            sectionHint("Drive times are from Bondi. A club with no published drive time is always shown.")
        }
    }

    private func driveBinding(bounds: FilterBounds) -> Binding<Double> {
        Binding(
            get: { Double(store.filters.maxDriveMinutes ?? bounds.maxDriveMinutes) },
            set: {
                store.filters = FilterMutation.setting(
                    maxDriveMinutes: Int($0.rounded()),
                    ceiling: bounds.maxDriveMinutes,
                    in: store.filters)
            })
    }

    // MARK: - Chrome

    private func sectionHint(_ text: String) -> some View {
        Text(text)
            .searchCaptionText()
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Controls

/// A full-width selectable row: title, optional subtitle, checkmark.
///
/// A row rather than a `Toggle` because the whole row is the hit target, and
/// rather than a segmented control because segmented controls truncate their
/// labels at AX5 instead of wrapping them.
struct FilterOptionRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: SearchStyle.gutter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).searchBodyText()
                    if let subtitle {
                        Text(subtitle).searchCaptionText()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
            .padding(.vertical, SearchStyle.rowSpacing)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small set of mutually exclusive choices, laid out as capsules that wrap
/// rather than as a segmented control that truncates.
struct FilterOptionGroup<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    let isSelected: (Option) -> Bool
    let select: (Option) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SearchStyle.chipSpacing) { capsules }
            VStack(alignment: .leading, spacing: SearchStyle.chipSpacing) { capsules }
        }
    }

    @ViewBuilder private var capsules: some View {
        ForEach(options, id: \.self) { option in
            let selected = isSelected(option)
            Button {
                select(option)
            } label: {
                Text(label(option))
                    .searchChipText()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SearchStyle.chipPadding)
                    .padding(.vertical, SearchStyle.chipPadding * 0.6)
                    .background(SearchStyle.chipBackground(isSelected: selected), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            SearchStyle.chipBorder(isSelected: selected),
                            lineWidth: selected ? 1.5 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(option))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// MARK: - Mutations, as pure functions

/// What each control in the sheet does to `SearchFilters`, lifted out of the
/// views.
///
/// There is no ViewInspector in this project, so a closure attached to a button
/// cannot be reached from a test. Naming the transformation instead means "tick
/// a second day and both days are in the filter" and "sliding the price to the
/// top means any price, not $110" are assertions rather than hopes.
public enum FilterMutation {

    /// 1 through 4. A tee time never seats more.
    public static let playerOptions = [1, 2, 3, 4]

    public static func toggling(day: String, in filters: SearchFilters) -> SearchFilters {
        var updated = filters
        if updated.days.contains(day) {
            updated.days.remove(day)
        } else {
            updated.days.insert(day)
        }
        return updated
    }

    public static func toggling(time: SearchFilters.TimeOfDay, in filters: SearchFilters) -> SearchFilters {
        var updated = filters
        if updated.timesOfDay.contains(time) {
            updated.timesOfDay.remove(time)
        } else {
            updated.timesOfDay.insert(time)
        }
        return updated
    }

    public static func setting(players: Int, in filters: SearchFilters) -> SearchFilters {
        var updated = filters
        updated.players = min(max(players, 1), 4)
        return updated
    }

    public static func setting(holes: SearchFilters.HolesFilter, in filters: SearchFilters) -> SearchFilters {
        var updated = filters
        updated.holes = holes
        return updated
    }

    /// The top of the slider is "any price", not "$110".
    ///
    /// Without this the most expensive round in the data would be a ceiling
    /// that quietly excludes anything a club prices above it tomorrow.
    public static func setting(maxPrice: Double, ceiling: Double, in filters: SearchFilters) -> SearchFilters {
        var updated = filters
        updated.maxPrice = maxPrice >= ceiling ? nil : maxPrice
        return updated
    }

    public static func setting(maxDriveMinutes: Int, ceiling: Int, in filters: SearchFilters) -> SearchFilters {
        var updated = filters
        updated.maxDriveMinutes = maxDriveMinutes >= ceiling ? nil : maxDriveMinutes
        return updated
    }

    public static func priceLabel(_ maxPrice: Double?) -> String {
        guard let maxPrice else { return "Any price" }
        return "Under \(SlotFormatting.money(maxPrice))"
    }

    public static func driveLabel(_ maxDriveMinutes: Int?) -> String {
        guard let maxDriveMinutes else { return "Any drive" }
        return "Under \(maxDriveMinutes) min from Bondi"
    }
}

// MARK: - Slider bounds

/// The ends of the price and drive sliders, taken from the data rather than
/// hardcoded.
///
/// The golden fixture runs $10–$110 and 10–45 minutes today. Pinning those
/// numbers in source means the day a club raises its green fee past the top of
/// the slider, the filter silently cannot reach it.
public struct FilterBounds: Equatable, Sendable {
    public let minPrice: Double
    public let maxPrice: Double
    public let minDriveMinutes: Int
    public let maxDriveMinutes: Int

    public static let priceStep: Double = 5
    public static let driveStep: Int = 5

    public init(minPrice: Double, maxPrice: Double, minDriveMinutes: Int, maxDriveMinutes: Int) {
        self.minPrice = minPrice
        // A slider whose ends are equal traps the thumb, so the top is always
        // at least one step above the bottom.
        self.maxPrice = Swift.max(maxPrice, minPrice + Self.priceStep)
        self.minDriveMinutes = minDriveMinutes
        self.maxDriveMinutes = Swift.max(maxDriveMinutes, minDriveMinutes + Self.driveStep)
    }

    /// Used before a payload has loaded, and when every slot in one is unpriced.
    public static let fallback = FilterBounds(
        minPrice: 10, maxPrice: 150, minDriveMinutes: 10, maxDriveMinutes: 60)

    public static func make(slots: [Slot], courses: [Course]) -> FilterBounds {
        var lowestPrice: Double?
        var highestPrice: Double?
        for price in slots.compactMap(\.priceMin) {
            lowestPrice = lowestPrice.map { Swift.min($0, price) } ?? price
            highestPrice = highestPrice.map { Swift.max($0, price) } ?? price
        }

        let drives = courses.compactMap(\.driveMinutesFromBondi)

        guard let lowestPrice, let highestPrice, let shortest = drives.min(), let longest = drives.max()
        else { return .fallback }

        return FilterBounds(
            minPrice: floorToStep(lowestPrice, step: priceStep),
            maxPrice: ceilToStep(highestPrice, step: priceStep),
            minDriveMinutes: Int(floorToStep(Double(shortest), step: Double(driveStep))),
            maxDriveMinutes: Int(ceilToStep(Double(longest), step: Double(driveStep))))
    }

    static func floorToStep(_ value: Double, step: Double) -> Double {
        (value / step).rounded(.down) * step
    }

    static func ceilToStep(_ value: Double, step: Double) -> Double {
        (value / step).rounded(.up) * step
    }
}

#if DEBUG
#Preview("Price") {
    FilterSheet(store: SearchStore.previewStore(), field: .price)
}

#Preview("Day") {
    FilterSheet(store: SearchStore.previewStore(), field: .day)
}
#endif
