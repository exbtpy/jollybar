import AppKit
import SwiftUI
import XCTest
@testable import GrokUsageBar

/// Renders one still of each companion mood. Headless ImageRenderer can fail
/// without a window server; that skips the test so CI stays green, and the
/// workflow uploads whatever PNGs were written.
@MainActor
final class CompanionPetSnapshotTests: XCTestCase {
    func testWritesPetStateSnapshots() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/pet-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let moods: [CompanionMood] = [.playful, .steady, .tired, .worried, .asleep]
        var wrote = 0
        for mood in moods {
            let view = CompanionPetPose(mood: mood, phase: 0.4)
                .frame(width: 180, height: 150)
                .padding(12)
                .background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage else {
                throw XCTSkip("ImageRenderer did not produce an image in this environment")
            }
            guard let png = pngData(from: image), !png.isEmpty else {
                throw XCTSkip("ImageRenderer image could not be encoded as PNG")
            }
            try png.write(to: directory.appendingPathComponent("\(mood.rawValue).png"))
            wrote += 1
        }
        XCTAssertEqual(wrote, moods.count)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
