import Foundation

package enum OpeningTitleTreatmentCategory: String, Codable, Sendable, CaseIterable {
    case standard
    case wild
    case close
    case wide

    package var displayName: String {
        switch self {
        case .standard:
            return "Standard Treatments"
        case .wild:
            return "Wild Treatments"
        case .close:
            return "Close Variants"
        case .wide:
            return "Wide Variants"
        }
    }

    package var boardFilename: String {
        "contact-sheet-\(rawValue).png"
    }
}

package struct TitleTreatmentPreviewEntry: Equatable, Sendable {
    package let treatment: OpeningTitleTreatment
    package let section: OpeningTitleTreatmentCategory
    package let badge: String?

    package init(
        treatment: OpeningTitleTreatment,
        section: OpeningTitleTreatmentCategory,
        badge: String? = nil
    ) {
        self.treatment = treatment
        self.section = section
        self.badge = badge
    }
}

package enum TitleTreatmentPreviewCollection: String, Codable, CaseIterable, Sendable {
    case classicExplorer = "classic-explorer"
    case currentCollageFamily = "current-collage-family"

    package static let `default`: TitleTreatmentPreviewCollection = .classicExplorer

    package var displayName: String {
        switch self {
        case .classicExplorer:
            return "Classic Explorer"
        case .currentCollageFamily:
            return "Current Collage Family"
        }
    }

    package var previewSelectionCount: Int {
        switch self {
        case .classicExplorer:
            return 6
        case .currentCollageFamily:
            return 10
        }
    }

    package var entries: [TitleTreatmentPreviewEntry] {
        switch self {
        case .classicExplorer:
            return Self.classicExplorerEntries
        case .currentCollageFamily:
            return Self.currentCollageFamilyEntries
        }
    }

    package var sections: [OpeningTitleTreatmentCategory] {
        switch self {
        case .classicExplorer:
            return [.standard, .wild]
        case .currentCollageFamily:
            return [.close, .wide]
        }
    }

    package func resolveEntries(requestedTreatments: [OpeningTitleTreatment]? = nil) -> [TitleTreatmentPreviewEntry] {
        guard let requestedTreatments, !requestedTreatments.isEmpty else {
            return entries
        }

        let requestedSet = Set(requestedTreatments)
        return entries.filter { requestedSet.contains($0.treatment) }
    }

    private static let classicExplorerEntries: [TitleTreatmentPreviewEntry] = [
        TitleTreatmentPreviewEntry(treatment: .currentCollage, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .legacyStatic, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .heroLowerThird, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .splitEditorial, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .contactSheetStamp, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .polaroidStack, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .filmstripMarquee, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .minimalDateSpotlight, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .centeredCinematic, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .triptychParallax, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .photoBookCover, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .museumPlaque, section: .standard),
        TitleTreatmentPreviewEntry(treatment: .kaleidoscopeBloom, section: .wild),
        TitleTreatmentPreviewEntry(treatment: .broadcastMeltdown, section: .wild),
        TitleTreatmentPreviewEntry(treatment: .cosmicOrbitarium, section: .wild),
        TitleTreatmentPreviewEntry(treatment: .scrapbookExplosion, section: .wild),
        TitleTreatmentPreviewEntry(treatment: .liquidChrome, section: .wild)
    ]

    private static let currentCollageFamilyEntries: [TitleTreatmentPreviewEntry] = [
        TitleTreatmentPreviewEntry(treatment: .currentCollage, section: .close, badge: "Control"),
        TitleTreatmentPreviewEntry(treatment: .collageSunriseGlow, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageMidnightNeon, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageSoftFilm, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageDenseMosaic, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageAiryHero, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageGentleFloat, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageParallaxSweep, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageKineticBounce, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageGlassTitle, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageEdgeLit, section: .close),
        TitleTreatmentPreviewEntry(treatment: .collageRibbonArc, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageCenterBurst, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageGalleryWall, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageFilmBurn, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageLightbox, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageCutoutChaos, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageReflectionPool, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageCascadeColumns, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collageOrbitRing, section: .wide),
        TitleTreatmentPreviewEntry(treatment: .collagePrismShift, section: .wide)
    ]
}

public enum OpeningTitleTreatment: String, CaseIterable, Codable, Sendable {
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
    case collageSunriseGlow = "collage-sunrise-glow"
    case collageMidnightNeon = "collage-midnight-neon"
    case collageSoftFilm = "collage-soft-film"
    case collageDenseMosaic = "collage-dense-mosaic"
    case collageAiryHero = "collage-airy-hero"
    case collageGentleFloat = "collage-gentle-float"
    case collageParallaxSweep = "collage-parallax-sweep"
    case collageKineticBounce = "collage-kinetic-bounce"
    case collageGlassTitle = "collage-glass-title"
    case collageEdgeLit = "collage-edge-lit"
    case collageRibbonArc = "collage-ribbon-arc"
    case collageCenterBurst = "collage-center-burst"
    case collageGalleryWall = "collage-gallery-wall"
    case collageFilmBurn = "collage-film-burn"
    case collageLightbox = "collage-lightbox"
    case collageCutoutChaos = "collage-cutout-chaos"
    case collageReflectionPool = "collage-reflection-pool"
    case collageCascadeColumns = "collage-cascade-columns"
    case collageOrbitRing = "collage-orbit-ring"
    case collagePrismShift = "collage-prism-shift"

    public static let allCases: [OpeningTitleTreatment] = [
        .currentCollage,
        .legacyStatic,
        .heroLowerThird,
        .splitEditorial,
        .contactSheetStamp,
        .polaroidStack,
        .filmstripMarquee,
        .minimalDateSpotlight,
        .centeredCinematic,
        .triptychParallax,
        .photoBookCover,
        .museumPlaque,
        .kaleidoscopeBloom,
        .broadcastMeltdown,
        .cosmicOrbitarium,
        .scrapbookExplosion,
        .liquidChrome,
        .collageSunriseGlow,
        .collageMidnightNeon,
        .collageSoftFilm,
        .collageDenseMosaic,
        .collageAiryHero,
        .collageGentleFloat,
        .collageParallaxSweep,
        .collageKineticBounce,
        .collageGlassTitle,
        .collageEdgeLit,
        .collageRibbonArc,
        .collageCenterBurst,
        .collageGalleryWall,
        .collageFilmBurn,
        .collageLightbox,
        .collageCutoutChaos,
        .collageReflectionPool,
        .collageCascadeColumns,
        .collageOrbitRing,
        .collagePrismShift
    ]

    package static let shippingDefault: OpeningTitleTreatment = .currentCollage
    package static let shippingRandomizedFamily: [OpeningTitleTreatment] =
        TitleTreatmentPreviewCollection.currentCollageFamily.entries.map(\.treatment)

    package static func randomizedShippingFamilyTreatment(for variationSeed: UInt64) -> OpeningTitleTreatment {
        guard !shippingRandomizedFamily.isEmpty else {
            return shippingDefault
        }

        let index = Int((variationSeed ^ 0x5EEDC011A63A1E51) % UInt64(shippingRandomizedFamily.count))
        return shippingRandomizedFamily[index]
    }

    package var classicExplorerCategory: OpeningTitleTreatmentCategory {
        switch self {
        case .kaleidoscopeBloom, .broadcastMeltdown, .cosmicOrbitarium, .scrapbookExplosion, .liquidChrome:
            return .wild
        case .currentCollage,
             .legacyStatic,
             .heroLowerThird,
             .splitEditorial,
             .contactSheetStamp,
             .polaroidStack,
             .filmstripMarquee,
             .minimalDateSpotlight,
             .centeredCinematic,
             .triptychParallax,
             .photoBookCover,
             .museumPlaque:
            return .standard
        case .collageSunriseGlow,
             .collageMidnightNeon,
             .collageSoftFilm,
             .collageDenseMosaic,
             .collageAiryHero,
             .collageGentleFloat,
             .collageParallaxSweep,
             .collageKineticBounce,
             .collageGlassTitle,
             .collageEdgeLit:
            return .close
        case .collageRibbonArc,
             .collageCenterBurst,
             .collageGalleryWall,
             .collageFilmBurn,
             .collageLightbox,
             .collageCutoutChaos,
             .collageReflectionPool,
             .collageCascadeColumns,
             .collageOrbitRing,
             .collagePrismShift:
            return .wide
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
        case .collageSunriseGlow:
            return "Collage Sunrise Glow"
        case .collageMidnightNeon:
            return "Collage Midnight Neon"
        case .collageSoftFilm:
            return "Collage Soft Film"
        case .collageDenseMosaic:
            return "Collage Dense Mosaic"
        case .collageAiryHero:
            return "Collage Airy Hero"
        case .collageGentleFloat:
            return "Collage Gentle Float"
        case .collageParallaxSweep:
            return "Collage Parallax Sweep"
        case .collageKineticBounce:
            return "Collage Kinetic Bounce"
        case .collageGlassTitle:
            return "Collage Glass Title"
        case .collageEdgeLit:
            return "Collage Edge Lit"
        case .collageRibbonArc:
            return "Collage Ribbon Arc"
        case .collageCenterBurst:
            return "Collage Center Burst"
        case .collageGalleryWall:
            return "Collage Gallery Wall"
        case .collageFilmBurn:
            return "Collage Film Burn"
        case .collageLightbox:
            return "Collage Lightbox"
        case .collageCutoutChaos:
            return "Collage Cutout Chaos"
        case .collageReflectionPool:
            return "Collage Reflection Pool"
        case .collageCascadeColumns:
            return "Collage Cascade Columns"
        case .collageOrbitRing:
            return "Collage Orbit Ring"
        case .collagePrismShift:
            return "Collage Prism Shift"
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
        case .collageSunriseGlow:
            return "The winning collage format warmed up with coral light, bloom, and gentle motion."
        case .collageMidnightNeon:
            return "A darker collage variant with neon accents, deeper contrast, and cooler highlights."
        case .collageSoftFilm:
            return "A muted collage pass with soft film warmth, quiet motion, and restrained contrast."
        case .collageDenseMosaic:
            return "A denser collage recipe using more, smaller cards for a busier opener."
        case .collageAiryHero:
            return "A more spacious collage with fewer, larger cards and a stronger title moment."
        case .collageGentleFloat:
            return "A calmer sibling that keeps the same layout language but drifts more softly."
        case .collageParallaxSweep:
            return "A collage variant with stronger horizontal parallax between layers."
        case .collageKineticBounce:
            return "A punchier collage with faster staggered arrivals and springier settle motion."
        case .collageGlassTitle:
            return "A frosted-glass title plate layered over the familiar floating collage cards."
        case .collageEdgeLit:
            return "A moodier collage with darker backdrops and cool edge lighting around the cards."
        case .collageRibbonArc:
            return "Cards sweep in an arc around the title for a more sculptural collage silhouette."
        case .collageCenterBurst:
            return "Cards burst outward from the title center before settling into a collage field."
        case .collageGalleryWall:
            return "The collage becomes a softly lit framed wall with drifting exhibition light."
        case .collageFilmBurn:
            return "A projector-inspired collage with warmth, dust, flicker, and light-leak energy."
        case .collageLightbox:
            return "A bright editorial collage with crisp shadows and off-white lightbox styling."
        case .collageCutoutChaos:
            return "A punchier collage made of irregular cutouts and layered overlaps."
        case .collageReflectionPool:
            return "Floating collage cards reflected on a glossy floor beneath the title."
        case .collageCascadeColumns:
            return "Tall staggered card columns drift past the title at different speeds."
        case .collageOrbitRing:
            return "Cards orbit loosely around a centered title block while keeping the collage feel."
        case .collagePrismShift:
            return "A refracted collage variant with ghosted duplicates and glassy color separation."
        }
    }
}
