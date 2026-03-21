import Core
import Foundation

struct PlexTVFilenameGenerator: Sendable {
    func makeOutputName(
        showTitle: String,
        monthYear: MonthYear,
        episodeTitleOverride: String? = nil
    ) -> String {
        PlexEpisodeIdentity(
            showTitle: showTitle,
            monthYear: monthYear,
            customEpisodeTitle: episodeTitleOverride
        ).filenameBase
    }
}
