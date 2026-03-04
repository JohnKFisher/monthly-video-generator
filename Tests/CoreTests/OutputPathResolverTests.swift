import Core
import Foundation
import XCTest

final class OutputPathResolverTests: XCTestCase {
    func testResolvesVersionedFilenameWhenCollisionExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = OutputTarget(directory: directory, baseFilename: "Monthly Slideshow")
        let first = try OutputPathResolver.resolveUniqueURL(target: target, container: .mov)
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = try OutputPathResolver.resolveUniqueURL(target: target, container: .mov)
        XCTAssertTrue(second.lastPathComponent.contains("-v2"))
    }
}
