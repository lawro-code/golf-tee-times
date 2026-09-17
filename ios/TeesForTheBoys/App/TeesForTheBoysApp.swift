import SwiftUI
import TeesContract
import TeesData
import TeesDesign
import TeesPush
import TeesViews

/// Stage 0 scaffold.
///
/// This is deliberately the thinnest thing that proves the whole chain: the
/// five modules link, the frozen contract decodes, and a real scrape's worth of
/// tee times reaches a screen. Stage 2 replaces the body with the real search
/// experience from TeesViews. Nothing here is a design decision.
@main
struct TeesForTheBoysApp: App {
    var body: some Scene {
        WindowGroup {
            ScaffoldView()
        }
    }
}

struct ScaffoldView: View {
    @State private var payload: ContractPayload?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView("Contract did not load", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if let payload {
                    List {
                        Section {
                            LabeledContent("Contract", value: payload.contractVersion)
                            LabeledContent("Scraped", value: payload.generatedAt)
                            LabeledContent("Courses", value: "\(payload.courses.count)")
                            LabeledContent("Tee times", value: "\(payload.slots.count)")
                            LabeledContent("Modules", value: moduleVersions)
                        } header: {
                            Text("Stage 0 scaffold")
                        }
                        Section("First 50 tee times") {
                            ForEach(payload.slots.prefix(50)) { slot in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(slot.teeTime.prefix(5))  \(slot.courseName)")
                                        .font(.headline)
                                    Text("\(slot.teeDate) · \(slot.holes) holes · par \(slot.par.map(String.init) ?? "—") · \(slot.spotsAvailable) of \(slot.totalSpots) free · \(priceText(slot))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tees for the Boys")
        }
        .task {
            do {
                payload = try ContractLoader.fixture("golden")
            } catch {
                failure = String(describing: error)
            }
        }
    }

    private var moduleVersions: String {
        [TeesDesignModule.version, TeesDataModule.version, TeesViewsModule.version, TeesPushModule.version]
            .joined(separator: " ")
    }

    private func priceText(_ slot: Slot) -> String {
        guard let min = slot.priceMin else { return "price at course" }
        if let max = slot.priceMax, max != min {
            return String(format: "$%.0f–$%.0f", min, max)
        }
        return String(format: "$%.0f", min)
    }
}
