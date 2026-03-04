import Foundation

public enum OutputPathResolver {
    public static func resolveUniqueURL(target: OutputTarget, container: ContainerFormat) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.directory, withIntermediateDirectories: true)

        let sanitizedBase = sanitizedFilename(target.baseFilename)
        let ext = container.fileExtension
        var candidate = target.directory.appendingPathComponent("\(sanitizedBase).\(ext)")

        var version = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = target.directory.appendingPathComponent("\(sanitizedBase)-v\(version).\(ext)")
            version += 1
        }

        return candidate
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Monthly Slideshow"
        }

        let disallowed = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let scalarView = trimmed.unicodeScalars.map { disallowed.contains($0) ? "-" : Character($0).description }
        return scalarView.joined()
    }
}
