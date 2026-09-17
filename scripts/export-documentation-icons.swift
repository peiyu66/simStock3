// Run from repository root: swift -module-cache-path /tmp/simstock-doc-icons-cache scripts/export-documentation-icons.swift
// Documentation assets only. Symbol names/colors mirror the sources listed in doc/icons/README.md.
import AppKit
import SwiftUI

struct IconSpec {
    let file: String
    let symbol: String
    let color: Color
    var opacity: Double = 1
    var weight: Font.Weight = .regular
}

@MainActor
func exportIcons() throws {
    let directory = URL(fileURLWithPath: "doc/icons", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var icons: [IconSpec] = [
        .init(file: "grade-wow", symbol: "star.square.fill", color: .red),
        .init(file: "grade-high", symbol: "2.square", color: .red),
        .init(file: "grade-fine", symbol: "1.square", color: .red),
        .init(file: "grade-none", symbol: "0.square", color: .gray),
        .init(file: "grade-weak", symbol: "1.square", color: .green),
        .init(file: "grade-low", symbol: "2.square", color: .green),
        .init(file: "grade-damn", symbol: "3.square", color: .green),
        .init(file: "grade-money-lacked", symbol: "star.square.fill", color: Color(nsColor: .darkGray)),
        .init(file: "improving-warning", symbol: "arrow.up.right.circle.fill", color: .orange, weight: .bold),
        .init(file: "worsening-warning", symbol: "arrow.down.right.circle.fill", color: Color(red: 0.60, green: 0.67, blue: 0.20), weight: .bold),
        .init(file: "prewarning", symbol: "exclamationmark.triangle", color: .orange, weight: .semibold),
        .init(file: "caution", symbol: "exclamationmark.triangle.fill", color: .orange, weight: .semibold),
        .init(file: "recovering", symbol: "clock.arrow.circlepath", color: .orange, weight: .semibold)
    ]
    for (name, symbol, color) in [
        ("peak", "arrow.up.right.circle.fill", Color.red),
        ("pullback", "arrow.down.right.circle", Color.red),
        ("bottom", "arrow.down.right.circle.fill", Color.green),
        ("rebound", "arrow.up.right.circle", Color.green)
    ] {
        for (stage, opacity) in [("early", 0.58), ("late", 1.0)] {
            icons.append(.init(file: "\(name)-\(stage)", symbol: symbol, color: color, opacity: opacity, weight: .bold))
        }
    }
    for (name, symbol) in [
        ("limit-up", "arrow.up.to.line"), ("limit-down", "arrow.down.to.line"),
        ("reverse", "circle"), ("reversed", "circle.fill"),
        ("selected", "checkmark.circle.fill"), ("technical", "waveform.path.ecg"),
        ("all-dates", "square.3.stack.3d"), ("filtered-dates", "square.2.stack.3d"),
        ("refresh", "arrow.clockwise"), ("settings", "wrench"),
        ("diagnostics", "doc.text"), ("help", "questionmark.circle"),
        ("cleanup", "externaldrive.badge.minus"), ("snapshot", "lock")
    ] {
        icons.append(.init(file: name, symbol: symbol, color: .primary))
    }
    icons.append(.init(file: "updated", symbol: "checkmark.circle", color: .green))
    for icon in icons {
        guard NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) != nil else {
            fatalError("Unavailable symbol: \(icon.symbol)")
        }
        let renderer = ImageRenderer(content:
            Image(systemName: icon.symbol)
                .font(.system(size: 28, weight: icon.weight))
                .foregroundStyle(icon.color.opacity(icon.opacity))
                .frame(width: 40, height: 40)
                .background(.white)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Failed rendering \(icon.file)")
        }
        try data.write(to: directory.appendingPathComponent("\(icon.file).png"))
    }
    print("Exported \(icons.count) icons")
}
try await exportIcons()
