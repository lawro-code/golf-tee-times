import SwiftUI
import XCTest
import TeesDesign

/// The module surface. Stage 0 left this file asserting only that the module
/// links; it now also proves the module has something in it, because "links"
/// was true of the empty placeholder too.
///
/// **This file imports `TeesDesign` without `@testable`, deliberately.** Every
/// other track reaches this module across a framework boundary, where only
/// `public` exists. A missing `public` on a token or a treatment compiles
/// fine, passes every `@testable` test in this bundle, and breaks track C the
/// moment it types the name. Here it fails to compile, which is the point.
final class TeesDesignSmokeTests: XCTestCase {

    func testModuleLinks() {
        XCTAssertFalse(TeesDesignModule.version.isEmpty)
        XCTAssertNotEqual(
            TeesDesignModule.version, "0",
            "still reporting the Stage 0 placeholder version"
        )
    }

    /// Stage 0's `"0"` is not a version anyone can compare against. The token
    /// layer has landed, so the module reports a real `major.minor.patch`.
    func testVersionIsASemanticVersionPastThePlaceholder() {
        let parts = TeesDesignModule.version.split(separator: ".").map(String.init)
        XCTAssertEqual(
            parts.count, 3,
            "expected major.minor.patch, got \"\(TeesDesignModule.version)\""
        )
        let numbers = parts.compactMap(Int.init)
        XCTAssertEqual(
            numbers.count, parts.count,
            "\"\(TeesDesignModule.version)\" has a component that is not a number"
        )
        XCTAssertGreaterThanOrEqual(
            numbers.first ?? 0, 1,
            "the token layer has shipped; the module is past its 0.x placeholder"
        )
    }

    /// One token from each layer the module claims to export, reached through
    /// its public name. If a layer is dropped or renamed, this stops compiling
    /// — which is the point: the names are a contract other tracks code
    /// against while this one is still being written.
    func testEveryTokenLayerIsReachable() {
        XCTAssertNotEqual(TeesFont.title, TeesFont.caption, "the type scale is not a scale")
        XCTAssertEqual(TeesSpacing.lg, 16)
        XCTAssertEqual(TeesRadius.sharp, 2)
        XCTAssertEqual(TeesRadius.control, 10)
        XCTAssertEqual(TeesStroke.leadingRule, 3)
        XCTAssertEqual(TeesLayout.minTapTarget, 44)
        XCTAssertNotEqual(TeesShadow.card, TeesShadow.board)

        let row = Text("06:16")
            .font(TeesFont.slotTime)
            .padding(TeesSpacing.md)
            .teesShadow(.card)
        XCTAssertTrue("\(type(of: row))".contains("ModifiedContent"))
    }

    /// The two tracked-caps treatments are in the module's exported table and
    /// are the two things track C reaches for by name most often, so they get
    /// the same across-the-boundary check as the value tokens.
    func testBothTrackedCapsTreatmentsAreReachableAcrossTheModuleBoundary() {
        let eyebrow = Text("round of the week").teesEyebrow()
        let meta = Text("northern beaches").teesMeta()
        XCTAssertTrue("\(type(of: eyebrow))".contains("ModifiedContent"))
        XCTAssertTrue("\(type(of: meta))".contains("ModifiedContent"))
    }

    /// `TeesShadow` is the one value type this module hands out, so another
    /// track has to be able to build one. A `public struct` with an internal
    /// memberwise initialiser is the default Swift gives you, and it fails
    /// here rather than in track C's build.
    func testAnotherTrackCanBuildAShadow() {
        let custom = TeesShadow(color: .black, radius: 3, x: 0, y: 2)
        XCTAssertEqual(custom.radius, 3)
        XCTAssertNotEqual(custom, TeesShadow.card)
    }
}
