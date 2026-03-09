import Core
import Foundation

struct PlexTVFilenameGenerator: Sendable {
    func makeOutputName(showTitle: String, monthYear: MonthYear) -> String {
        PlexEpisodeIdentity(showTitle: showTitle, monthYear: monthYear).filenameBase
    }
}
