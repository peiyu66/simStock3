import SwiftUI
import UIKit
import XCTest
@testable import simStock3

@MainActor final class TaiwanDatePickerTests: XCTestCase {
    func testProductionPickerUsesTaiwanCalendarAndInstantInEveryDeviceZone() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let chosen = twDateTime.dateFromString("2024/02/29")!
        let now = twDateTime.dateFromString("2026/10/23 00:00:00", format: "yyyy/MM/dd HH:mm:ss")!
        for zone in ["Asia/Taipei", "UTC", "America/Los_Angeles"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let host = UIHostingController(rootView: TaiwanSimulationDatePicker(selection: .constant(chosen), asOf: now)
                .datePickerStyle(.wheel))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            func pickers(_ view: UIView) -> [UIDatePicker] {
                (view as? UIDatePicker).map { [$0] } ?? view.subviews.flatMap(pickers)
            }
            let picker = try XCTUnwrap(pickers(host.view).first, zone)
            XCTAssertEqual(picker.timeZone?.identifier, "Asia/Taipei", zone)
            XCTAssertEqual(picker.calendar.identifier, .gregorian, zone)
            XCTAssertEqual(picker.date, chosen, zone)
            XCTAssertEqual(picker.minimumDate, twDateTime.simulationStartRange(asOf: now).lowerBound, zone)
            XCTAssertEqual(picker.maximumDate, twDateTime.simulationStartRange(asOf: now).upperBound, zone)
            window.isHidden = true
        }
    }
}
