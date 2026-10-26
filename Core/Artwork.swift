import Foundation

/// A run of museum-written text, optionally italic (the museum marks titles of works with `<em>`).
struct TextRun: Codable, Hashable, Sendable {
    var text: String
    var isItalic: Bool
}

/// Museum-written educational text, kept in the museum's original wording.
/// The only transformation applied is HTML-to-text cleanup (see `MuseumTextFormatter`).
struct MuseumText: Codable, Hashable, Sendable {
    enum Field: String, Codable, Sendable, CaseIterable {
        case description
        case artlensDescription = "artlens_description"
        case didYouKnow = "did_you_know"

        /// Preference order for the primary text, as specified by the museum fields.
        static let preferenceOrder: [Field] = [.description, .artlensDescription, .didYouKnow]

        var heading: String {
            switch self {
            case .description: return "About this work"
            case .artlensDescription: return "From ArtLens"
            case .didYouKnow: return "Did you know?"
            }
        }
    }

    var field: Field
    var runs: [TextRun]

    var plainText: String { runs.map(\.text).joined() }
}

/// Reference to one rendition of an artwork image hosted by the museum.
struct ArtworkImageRef: Codable, Hashable, Sendable {
    var url: URL
    var width: Int
    var height: Int
    var fileSize: Int?

    var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 1 }
    var longestEdge: Int { max(width, height) }
    var shortestEdge: Int { min(width, height) }
}

/// A cleaned, validated artwork that passed `ArtworkEligibilityFilter`.
struct Artwork: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var accessionNumber: String?
    var title: String
    var creationDate: String?
    /// Artist line as written by the museum, e.g. "George Bellows (American, 1882–1925)".
    var creators: [String]
    var culture: String?
    var technique: String?
    var type: String?
    var department: String?
    var creditLine: String?
    var tombstone: String?
    var collectionURL: URL?
    var isHighlight: Bool
    var licenseStatus: String
    /// The first available text in `MuseumText.Field.preferenceOrder`.
    var primaryText: MuseumText
    /// Any other museum text fields that were present, in preference order.
    var additionalTexts: [MuseumText]
    /// The image used for wallpapers (the museum's "print" JPEG).
    var image: ArtworkImageRef
    /// Small "web" JPEG, used only for quick previews.
    var previewImage: ArtworkImageRef?

    /// Attribution shown on labels. Many non-Western and ancient works have no named
    /// maker; the museum identifies those by culture instead.
    var attribution: String {
        if !creators.isEmpty { return creators.joined(separator: "; ") }
        if let culture, !culture.isEmpty { return culture }
        return "Unknown maker"
    }

    var didYouKnow: MuseumText? {
        ([primaryText] + additionalTexts).first { $0.field == .didYouKnow && $0 != primaryText }
    }

    /// Museum page, falling back to the canonical URL pattern if the record omitted it.
    var webURL: URL? {
        if let collectionURL { return collectionURL }
        guard let accessionNumber,
              let encoded = accessionNumber.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://www.clevelandart.org/art/\(encoded)")
    }
}
