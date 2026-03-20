import Foundation

package enum OpeningTitleTreatmentCategory: String, Codable, Sendable {
    case standard
    case wild
}

package enum OpeningTitleTreatment: String, CaseIterable, Codable, Sendable {
    case currentCollage = "current-collage"
    case legacyStatic = "legacy-static"
    case heroLowerThird = "hero-lower-third"
    case splitEditorial = "split-editorial"
    case contactSheetStamp = "contact-sheet-stamp"
    case polaroidStack = "polaroid-stack"
    case filmstripMarquee = "filmstrip-marquee"
    case minimalDateSpotlight = "minimal-date-spotlight"
    case centeredCinematic = "centered-cinematic"
    case triptychParallax = "triptych-parallax"
    case photoBookCover = "photo-book-cover"
    case museumPlaque = "museum-plaque"
    case kaleidoscopeBloom = "kaleidoscope-bloom"
    case broadcastMeltdown = "broadcast-meltdown"
    case cosmicOrbitarium = "cosmic-orbitarium"
    case scrapbookExplosion = "scrapbook-explosion"
    case liquidChrome = "liquid-chrome"

    package static let shippingDefault: OpeningTitleTreatment = .currentCollage

    package var category: OpeningTitleTreatmentCategory {
        switch self {
        case .kaleidoscopeBloom, .broadcastMeltdown, .cosmicOrbitarium, .scrapbookExplosion, .liquidChrome:
            return .wild
        default:
            return .standard
        }
    }

    package var displayName: String {
        switch self {
        case .currentCollage:
            return "Current Collage"
        case .legacyStatic:
            return "Legacy Static"
        case .heroLowerThird:
            return "Hero Lower Third"
        case .splitEditorial:
            return "Split Editorial"
        case .contactSheetStamp:
            return "Contact Sheet Stamp"
        case .polaroidStack:
            return "Polaroid Stack"
        case .filmstripMarquee:
            return "Filmstrip Marquee"
        case .minimalDateSpotlight:
            return "Minimal Date Spotlight"
        case .centeredCinematic:
            return "Centered Cinematic"
        case .triptychParallax:
            return "Triptych Parallax"
        case .photoBookCover:
            return "Photo Book Cover"
        case .museumPlaque:
            return "Museum Plaque"
        case .kaleidoscopeBloom:
            return "Kaleidoscope Bloom"
        case .broadcastMeltdown:
            return "Broadcast Meltdown"
        case .cosmicOrbitarium:
            return "Cosmic Orbitarium"
        case .scrapbookExplosion:
            return "Scrapbook Explosion"
        case .liquidChrome:
            return "Liquid Chrome"
        }
    }

    package var shortDescription: String {
        switch self {
        case .currentCollage:
            return "The current animated media-collage opener used by the shipping app."
        case .legacyStatic:
            return "The legacy dark static title card as a baseline."
        case .heroLowerThird:
            return "A cinematic hero frame with the title anchored in a lower-third block."
        case .splitEditorial:
            return "An editorial split layout with a text column and floating preview stack."
        case .contactSheetStamp:
            return "A tidy contact-sheet grid with a stamped central title lockup."
        case .polaroidStack:
            return "Layered instant-film cards with a relaxed scrapbook motion."
        case .filmstripMarquee:
            return "A moving filmstrip treatment with marquee-style preview crops."
        case .minimalDateSpotlight:
            return "A restrained spotlight composition with oversized month typography."
        case .centeredCinematic:
            return "A prestige-film style centered lockup over a single hero image."
        case .triptychParallax:
            return "Three tall panels moving at different speeds behind the title."
        case .photoBookCover:
            return "A premium printed-album cover treatment with quiet serif typography."
        case .museumPlaque:
            return "A gallery wall look with a framed hero image and metadata plaque."
        case .kaleidoscopeBloom:
            return "Mirrored slices blooming around a calm, centered title plate."
        case .broadcastMeltdown:
            return "A faux station-ID with scanlines, countdown energy, and RGB breakup."
        case .cosmicOrbitarium:
            return "Orbiting preview moons over a starfield with a dramatic central title."
        case .scrapbookExplosion:
            return "A maximal scrapbook collage with torn paper, tape, and stamped details."
        case .liquidChrome:
            return "A glossy surreal treatment with chrome blobs, glows, and oversized type."
        }
    }
}
