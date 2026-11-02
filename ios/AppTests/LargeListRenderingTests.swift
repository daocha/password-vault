import XCTest
import SwiftUI
import UIKit
import VaultCore
@testable import PassVault

/// Measure the real SwiftUI list with the states produced by an icon tap and Select All.
/// Only in-memory synthetic records are used; the test never changes the device's stored vault.
@MainActor final class LargeListRenderingTests: XCTestCase {
    func testRenderingSingleSelectionWith501Entries() throws { try measureSelection(selectAll: false) }
    func testRenderingSelectAllWith501Entries() throws { try measureSelection(selectAll: true) }

    private func measureSelection(selectAll: Bool) throws {
        let records = (0..<501).map { index -> VaultRecord in
            var record = VaultRecord()
            record.id = "entry-\(index)"; record.name = String(format: "Entry %03d", index)
            record.group = index < 25 ? "Small folder" : "Other"
            return record
        }
        let model = VaultModel(engine: VaultEngine(storage: ModelTestStorage()))
        model.records = records; model.unlocked = true
        let ids: Set<String> = selectAll ? Set(records.map(\.id)) : [records[0].id]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let host = UIHostingController(rootView: RecordList(initialSelection: ids).environmentObject(model))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            window.rootViewController = nil
        }
        XCTAssertEqual(model.records, records)
    }
}
