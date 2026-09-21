import SwiftUI
import TeesContract
import TeesDesign

/// The optional detour off the one-tap path.
///
/// It exists for the golfer who wanted the 8am rather than "a morning", and for
/// nobody else. It is reachable **only** from the confirmation that appears
/// after `AlertFromSearchButton` has already saved the watch — never on the way
/// in, never as a step. If this sheet ever appears before a watch exists, the
/// feature has been broken.
///
/// The sentence is restated live at the top as the form is edited, because the
/// sentence is the watch: someone reading "Alert me when a twilight tee time
/// opens on Saturday at The Coast" knows exactly what they will be woken up
/// for, in a way that seven form rows never convey.
///
/// Cancel leaves the original alone. Save hands back a draft with the same
/// `id`, so the data layer updates the watch instead of creating a second one.
public struct AlertAdjustSheet: View {

    private let original: WatchDraft
    private let onSave: (WatchDraft) -> Void
    private let onCancel: () -> Void

    @State private var filters: SearchFilters
    /// Remembered separately so switching the price limit off and on again does
    /// not lose the number the golfer had already dialled in.
    @State private var priceCeiling: Double
    @State private var driveCeiling: Int

    @Environment(\.dismiss) private var dismiss

    public init(
        draft: WatchDraft,
        onSave: @escaping (WatchDraft) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.original = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _filters = State(initialValue: draft.filters)
        _priceCeiling = State(initialValue: draft.filters.maxPrice ?? 60)
        _driveCeiling = State(initialValue: draft.filters.maxDriveMinutes ?? 30)
    }

    /// The draft as it stands right now. Rebuilt on every edit, which is cheap
    /// — the sentences are two string joins — and is what keeps the restatement
    /// honest rather than approximate.
    private var preview: WatchDraft {
        original.updating(filters: filters)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(preview.sentence)
                        .font(TeesFont.bodyStrong)
                        .foregroundStyle(TeesColor.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(preview.sentence))
                } header: {
                    Text("This alert")
                }

                daysSection
                timeSection
                roundSection
                limitsSection
                clubsSection
            }
            .tint(TeesColor.green)
            .navigationTitle("Adjust alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preview)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Days

    private var candidateDays: [String] {
        Self.candidateDays(from: original.today)
    }

    /// The six days the scraper covers: today plus five (CONTRACT.md — "full"
    /// is days 0-5).
    ///
    /// Derived from the injected `today` by walking wall-clock date strings,
    /// never by adding 86,400 seconds to an instant — which is what makes it
    /// survive the October night Sydney's clocks go forward and a day is only
    /// 23 hours long.
    static func candidateDays(from today: String) -> [String] {
        var days: [String] = [today]
        var cursor = today
        for _ in 0..<5 {
            guard let next = SlotFormatting.dayAfter(cursor) else { break }
            days.append(next)
            cursor = next
        }
        return days
    }

    private var daysSection: some View {
        Section {
            ForEach(candidateDays, id: \.self) { day in
                Toggle(
                    SlotFormatting.dayTitle(for: day, today: original.today),
                    isOn: binding(
                        contains: day,
                        in: \.days
                    )
                )
            }
        } header: {
            Text("Days")
        } footer: {
            Text("Nothing selected means any day.")
        }
    }

    // MARK: - Time

    private var timeSection: some View {
        Section {
            ForEach(SearchFilters.TimeOfDay.allCases, id: \.self) { bucket in
                Toggle(isOn: binding(contains: bucket, in: \.timesOfDay)) {
                    VStack(alignment: .leading, spacing: TeesSpacing.xxs) {
                        Text(bucket.title)
                        Text(bucket.subtitle)
                            .font(TeesFont.caption)
                            .foregroundStyle(TeesColor.muted)
                    }
                }
                .accessibilityLabel(Text("\(bucket.title), \(bucket.subtitle)"))
            }
        } header: {
            Text("Time of day")
        } footer: {
            Text("Nothing selected means any time.")
        }
    }

    // MARK: - The round

    private var roundSection: some View {
        Section("The round") {
            Picker("Holes", selection: $filters.holes) {
                ForEach(SearchFilters.HolesFilter.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            Stepper(value: $filters.players, in: 1...4) {
                Text(filters.players == 1 ? "Any group size" : "Room for \(filters.players)")
            }
        }
    }

    // MARK: - Limits

    private var limitsSection: some View {
        Section {
            Toggle("Limit the price", isOn: priceLimitBinding)
            if filters.maxPrice != nil {
                VStack(alignment: .leading, spacing: TeesSpacing.xs) {
                    Text("Under \(SlotFormatting.money(priceCeiling))")
                        .font(TeesFont.body)
                        .foregroundStyle(TeesColor.ink)
                    Slider(value: priceBinding, in: 20...200, step: 5) {
                        Text("Maximum price")
                    }
                }
            }
            Toggle("Limit the drive", isOn: driveLimitBinding)
            if filters.maxDriveMinutes != nil {
                Stepper(value: driveBinding, in: 10...90, step: 5) {
                    Text("Within \(driveCeiling) min of Bondi")
                }
            }
        } header: {
            Text("Limits")
        } footer: {
            // CONTRACT.md §3: one slot in six publishes no fee at all, and a
            // price filter never silently drops one.
            Text("Clubs that publish no fee are still shown \u{2014} about one tee time in six.")
        }
    }

    private var priceLimitBinding: Binding<Bool> {
        Binding(
            get: { filters.maxPrice != nil },
            set: { filters.maxPrice = $0 ? priceCeiling : nil }
        )
    }

    private var priceBinding: Binding<Double> {
        Binding(
            get: { priceCeiling },
            set: {
                priceCeiling = $0
                filters.maxPrice = $0
            }
        )
    }

    private var driveLimitBinding: Binding<Bool> {
        Binding(
            get: { filters.maxDriveMinutes != nil },
            set: { filters.maxDriveMinutes = $0 ? driveCeiling : nil }
        )
    }

    private var driveBinding: Binding<Int> {
        Binding(
            get: { driveCeiling },
            set: {
                driveCeiling = $0
                filters.maxDriveMinutes = $0
            }
        )
    }

    // MARK: - Clubs

    private var clubsSection: some View {
        Section {
            ForEach(original.courses) { course in
                Toggle(
                    SlotFormatting.shortCourseName(course.name),
                    isOn: binding(contains: course.slug, in: \.courseSlugs)
                )
            }
        } header: {
            Text("Clubs")
        } footer: {
            Text("Nothing selected means any club.")
        }
    }

    // MARK: - Set bindings

    /// A `Toggle` over one member of a `Set` on the filters. Written once
    /// rather than three times, because the days, the time buckets and the
    /// clubs are all the same interaction.
    private func binding<Element: Hashable>(
        contains element: Element,
        in keyPath: WritableKeyPath<SearchFilters, Set<Element>>
    ) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath].contains(element) },
            set: { isOn in
                if isOn {
                    filters[keyPath: keyPath].insert(element)
                } else {
                    filters[keyPath: keyPath].remove(element)
                }
            }
        )
    }
}

#Preview("Adjust") {
    AlertAdjustSheet(
        draft: WatchDraft(
            filters: SearchFilters(days: ["2026-09-19"], timesOfDay: [.morning]),
            courses: [],
            today: "2026-09-18"
        ),
        onSave: { _ in }
    )
}
