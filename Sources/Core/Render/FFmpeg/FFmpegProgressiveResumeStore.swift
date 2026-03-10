import Foundation

struct FFmpegProgressiveResumeSession: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case active
        case paused
    }

    static let schemaVersion = 1

    let schemaVersion: Int
    let sessionID: UUID
    let planSignature: String
    let outputDirectoryURL: URL
    let outputBaseFilename: String
    let workDirectoryURL: URL
    let finalOutputURL: URL
    let createdAt: Date
    var updatedAt: Date
    var state: State
    var completedPresentationIndices: [Int]
    var completedBatchIndices: [Int]
    var concatCompleted: Bool

    init(
        sessionID: UUID,
        planSignature: String,
        outputDirectoryURL: URL,
        outputBaseFilename: String,
        workDirectoryURL: URL,
        finalOutputURL: URL,
        createdAt: Date,
        updatedAt: Date,
        state: State,
        completedPresentationIndices: [Int] = [],
        completedBatchIndices: [Int] = [],
        concatCompleted: Bool = false
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        self.planSignature = planSignature
        self.outputDirectoryURL = outputDirectoryURL
        self.outputBaseFilename = outputBaseFilename
        self.workDirectoryURL = workDirectoryURL
        self.finalOutputURL = finalOutputURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.completedPresentationIndices = completedPresentationIndices.sorted()
        self.completedBatchIndices = completedBatchIndices.sorted()
        self.concatCompleted = concatCompleted
    }

    var manifestURL: URL {
        workDirectoryURL.appendingPathComponent("resume-session.json")
    }

    var chapterMetadataURL: URL {
        workDirectoryURL.appendingPathComponent("chapters.ffmeta")
    }

    var concatListURL: URL {
        workDirectoryURL.appendingPathComponent("final.ffconcat")
    }

    var concatOutputURL: URL {
        workDirectoryURL.appendingPathComponent("final-concat.mov")
    }

    func presentationOutputURL(for index: Int) -> URL {
        workDirectoryURL.appendingPathComponent(String(format: "presentation-%04d.mov", index))
    }

    func batchOutputURL(for index: Int) -> URL {
        workDirectoryURL.appendingPathComponent(String(format: "batch-%04d.mov", index))
    }
}

final class FFmpegProgressiveResumeStore {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL ?? Self.defaultBaseDirectoryURL(fileManager: fileManager)
        self.now = now
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func pruneStaleSessions(
        maximumSessionCount: Int = 5,
        maximumAgeDays: Double = 7
    ) {
        let sessions = loadAllSessions().sorted { $0.updatedAt > $1.updatedAt }
        let now = now()
        let maxAge = maximumAgeDays * 24 * 60 * 60

        for session in sessions.dropFirst(maximumSessionCount) {
            removeSession(session)
        }

        for session in sessions where now.timeIntervalSince(session.updatedAt) > maxAge {
            removeSession(session)
        }
    }

    func findPausedSession(
        planSignature: String,
        outputTarget: OutputTarget
    ) -> FFmpegProgressiveResumeSession? {
        loadAllSessions().first {
            $0.planSignature == planSignature &&
                $0.outputDirectoryURL == outputTarget.directory &&
                $0.outputBaseFilename == outputTarget.baseFilename &&
                $0.state == .paused
        }
    }

    func createSession(
        planSignature: String,
        outputTarget: OutputTarget,
        finalOutputURL: URL
    ) throws -> FFmpegProgressiveResumeSession {
        try createBaseDirectoryIfNeeded()
        let sessionID = UUID()
        let workDirectoryURL = baseDirectoryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
        let timestamp = now()
        let session = FFmpegProgressiveResumeSession(
            sessionID: sessionID,
            planSignature: planSignature,
            outputDirectoryURL: outputTarget.directory,
            outputBaseFilename: outputTarget.baseFilename,
            workDirectoryURL: workDirectoryURL,
            finalOutputURL: finalOutputURL,
            createdAt: timestamp,
            updatedAt: timestamp,
            state: .active
        )
        try save(session)
        return session
    }

    func save(_ session: FFmpegProgressiveResumeSession) throws {
        try createBaseDirectoryIfNeeded()
        try fileManager.createDirectory(at: session.workDirectoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: session.manifestURL, options: .atomic)
    }

    func markActive(_ session: inout FFmpegProgressiveResumeSession) throws {
        session.state = .active
        session.updatedAt = now()
        try save(session)
    }

    func markPaused(_ session: inout FFmpegProgressiveResumeSession) throws {
        session.state = .paused
        session.updatedAt = now()
        try save(session)
    }

    func markPresentationCompleted(
        _ index: Int,
        session: inout FFmpegProgressiveResumeSession
    ) throws {
        if !session.completedPresentationIndices.contains(index) {
            session.completedPresentationIndices.append(index)
            session.completedPresentationIndices.sort()
        }
        session.updatedAt = now()
        try save(session)
    }

    func markBatchCompleted(
        _ index: Int,
        session: inout FFmpegProgressiveResumeSession
    ) throws {
        if !session.completedBatchIndices.contains(index) {
            session.completedBatchIndices.append(index)
            session.completedBatchIndices.sort()
        }
        session.updatedAt = now()
        try save(session)
    }

    func markConcatCompleted(_ session: inout FFmpegProgressiveResumeSession) throws {
        session.concatCompleted = true
        session.updatedAt = now()
        try save(session)
    }

    func removeSession(_ session: FFmpegProgressiveResumeSession) {
        do {
            if fileManager.fileExists(atPath: session.workDirectoryURL.path) {
                try fileManager.removeItem(at: session.workDirectoryURL)
            }
        } catch {
            // Cleanup failures should not abort a render completion/failure path.
        }
    }

    static func planSignature(
        for plan: FFmpegRenderPlan,
        outputTarget: OutputTarget
    ) -> String {
        var parts: [String] = [
            "outputDirectory=\(outputTarget.directory.path)",
            "outputBase=\(outputTarget.baseFilename)",
            "transition=\(format(plan.transitionDurationSeconds))",
            "endFade=\(format(plan.endFadeToBlackDurationSeconds))",
            "renderSize=\(Int(plan.renderSize.width.rounded()))x\(Int(plan.renderSize.height.rounded()))",
            "frameRate=\(plan.frameRate)",
            "audioLayout=\(plan.audioLayout.rawValue)",
            "bitrate=\(plan.bitrateMode.rawValue)",
            "container=\(plan.container.rawValue)",
            "codec=\(plan.videoCodec.rawValue)",
            "dynamicRange=\(plan.dynamicRange.rawValue)",
            "hdrHEVCEncoderMode=\(plan.hdrHEVCEncoderMode.rawValue)",
            "renderIntent=\(plan.renderIntent.rawValue)"
        ]

        for (index, clip) in plan.clips.enumerated() {
            parts.append(
                "clip[\(index)]=\(clip.sourceDescription)|duration=\(format(clip.durationSeconds))|includeAudio=\(clip.includeAudio)|" +
                    "hasAudioTrack=\(clip.hasAudioTrack)|isHDR=\(clip.colorInfo.isHDR)|primaries=\(clip.colorInfo.colorPrimaries ?? "nil")|" +
                    "transfer=\(clip.colorInfo.transferFunction ?? "nil")|transferFlavor=\(clip.colorInfo.transferFlavor.rawValue)|" +
                    "hdrMetadata=\(clip.colorInfo.hdrMetadataFlavor.rawValue)|overlay=\(clip.captureDateOverlayURL != nil)"
            )
        }

        for (index, chapter) in plan.chapters.enumerated() {
            parts.append(
                "chapter[\(index)]=\(chapter.kind.rawValue)|\(chapter.title)|start=\(format(chapter.startTimeSeconds))|end=\(format(chapter.endTimeSeconds))"
            )
        }

        if let metadata = plan.embeddedMetadata {
            parts.append(
                "metadata=\(metadata.title)|\(metadata.description)|\(metadata.synopsis)|\(metadata.comment)|\(metadata.show)|" +
                    "\(metadata.seasonNumber)|\(metadata.episodeSort)|\(metadata.episodeID)|\(metadata.date)|\(metadata.genre)"
            )
            parts.append("metadataCreationTime=\(metadata.creationTime?.timeIntervalSince1970 ?? -1)")
            if let provenance = metadata.provenance {
                parts.append("provenance=\(provenance.software)|\(provenance.version)|\(provenance.information)")
                for key in provenance.customEntries.keys.sorted() {
                    parts.append("custom=\(key)=\(provenance.customEntries[key] ?? "")")
                }
            }
        }

        return parts.joined(separator: "\n")
    }

    private func loadAllSessions() -> [FFmpegProgressiveResumeSession] {
        guard fileManager.fileExists(atPath: baseDirectoryURL.path),
              let directoryContents = try? fileManager.contentsOfDirectory(
                at: baseDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return directoryContents.compactMap { directoryURL in
            let manifestURL = directoryURL.appendingPathComponent("resume-session.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let session = try? decoder.decode(FFmpegProgressiveResumeSession.self, from: data),
                  session.schemaVersion == FFmpegProgressiveResumeSession.schemaVersion else {
                return nil
            }
            return session
        }
    }

    private func createBaseDirectoryIfNeeded() throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
    }

    private static func defaultBaseDirectoryURL(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory
        return root
            .appendingPathComponent("Monthly Video Generator", isDirectory: true)
            .appendingPathComponent("ResumableRenders", isDirectory: true)
    }
}

final class FFmpegProgressivePauseState {
    private let lock = NSLock()
    private var requested = false

    func requestPause() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        requested = false
        lock.unlock()
    }

    var isPauseRequested: Bool {
        lock.lock()
        let value = requested
        lock.unlock()
        return value
    }
}

private func format(_ value: Double) -> String {
    String(format: "%.6f", value)
}
