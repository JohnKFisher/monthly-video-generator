import Core
import Foundation

private struct Options {
    var inputFolderURL = URL(fileURLWithPath: "/Users/jkfisher/Desktop/VideoTestFolder", isDirectory: true)
    var title = "March 2026"
    var caption = "Fisher Family Videos"
    var outputRootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("tmp/title-treatment-previews", isDirectory: true)
    var outputDirectoryOverride: URL?
    var durationSeconds = 7.5
    var renderSize = CGSize(width: 1920, height: 1080)
    var treatments = OpeningTitleTreatment.allCases
}

@main
struct TitleTreatmentPreviewGeneratorMain {
    static func main() async {
        do {
            let options = try parseOptions(arguments: CommandLine.arguments)
            let service = TitleTreatmentPreviewGeneratorService()
            let result = try await service.generate(
                config: TitleTreatmentPreviewConfiguration(
                    inputFolderURL: options.inputFolderURL,
                    title: options.title,
                    caption: options.caption,
                    outputRootDirectory: options.outputRootURL,
                    outputDirectoryOverride: options.outputDirectoryOverride,
                    durationSeconds: options.durationSeconds,
                    renderSize: options.renderSize,
                    treatments: options.treatments
                )
            )
            print("Title treatment previews generated at:")
            print(result.outputDirectory.path)
            print("Open:")
            print(result.indexURL.path)
        } catch {
            fputs("TitleTreatmentPreviewGenerator failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private func parseOptions(arguments: [String]) throws -> Options {
    var options = Options()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--help", "-h":
            printUsageAndExit()
        case "--input":
            index += 1
            options.inputFolderURL = URL(fileURLWithPath: try requireValue(arguments, index: index, for: argument), isDirectory: true)
        case "--title":
            index += 1
            options.title = try requireValue(arguments, index: index, for: argument)
        case "--caption":
            index += 1
            options.caption = try requireValue(arguments, index: index, for: argument)
        case "--output-root":
            index += 1
            options.outputRootURL = URL(fileURLWithPath: try requireValue(arguments, index: index, for: argument), isDirectory: true)
        case "--output-dir":
            index += 1
            options.outputDirectoryOverride = URL(fileURLWithPath: try requireValue(arguments, index: index, for: argument), isDirectory: true)
        case "--duration":
            index += 1
            options.durationSeconds = Double(try requireValue(arguments, index: index, for: argument)) ?? options.durationSeconds
        case "--width":
            index += 1
            let width = Double(try requireValue(arguments, index: index, for: argument)) ?? Double(options.renderSize.width)
            options.renderSize.width = width
        case "--height":
            index += 1
            let height = Double(try requireValue(arguments, index: index, for: argument)) ?? Double(options.renderSize.height)
            options.renderSize.height = height
        case "--treatments":
            index += 1
            let rawValue = try requireValue(arguments, index: index, for: argument)
            let requested = rawValue
                .split(separator: ",")
                .compactMap { OpeningTitleTreatment(rawValue: String($0)) }
            if !requested.isEmpty {
                options.treatments = requested
            }
        default:
            throw NSError(
                domain: "TitleTreatmentPreviewGenerator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown argument: \(argument)"]
            )
        }
        index += 1
    }

    return options
}

private func requireValue(_ arguments: [String], index: Int, for flag: String) throws -> String {
    guard index < arguments.count else {
        throw NSError(
            domain: "TitleTreatmentPreviewGenerator",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Missing value for \(flag)"]
        )
    }
    return arguments[index]
}

private func printUsageAndExit() -> Never {
    print(
        """
        Usage: swift run TitleTreatmentPreviewGenerator [options]

          --input <folder>          Source folder. Default: /Users/jkfisher/Desktop/VideoTestFolder
          --title <text>            Title text. Default: March 2026
          --caption <text>          Small caption. Default: Fisher Family Videos
          --output-root <folder>    Root folder for timestamped preview sets. Default: tmp/title-treatment-previews
          --output-dir <folder>     Exact output directory override.
          --duration <seconds>      Clip duration. Default: 7.5
          --width <pixels>          Render width. Default: 1920
          --height <pixels>         Render height. Default: 1080
          --treatments <csv>        Comma-separated treatment slugs to render.
          --help                    Show this help.
        """
    )
    Foundation.exit(0)
}
