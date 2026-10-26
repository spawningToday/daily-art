import Foundation

/// Which part of the collection the app draws from.
enum CollectionScope: String, Codable, CaseIterable, Sendable {
    /// Works the museum itself designates as collection highlights (default).
    case highlights
    /// Every CC0 work with an image and museum-written text. Uncurated; opt-in only.
    case expanded
}

/// Decides whether an API record may be shown, using only objective, technical rules.
/// There is deliberately no aesthetic scoring: curation is left entirely to the museum.
struct ArtworkEligibilityFilter: Sendable {
    enum Rejection: String, Error, Codable, CaseIterable, Sendable {
        case notHighlight = "Not a museum highlight"
        case notCC0 = "Image not released under CC0"
        case missingImage = "No print-resolution JPEG"
        case imageTooSmall = "Image too small for a Mac display"
        case extremeAspectRatio = "Extreme proportions (e.g. hand scrolls)"
        case missingText = "No museum-written description"
    }

    var scope: CollectionScope = .highlights
    /// The shorter image edge must be at least this many pixels. Verified data: all
    /// highlight "print" JPEGs are ≥ 1957 px on the long edge; four hand scrolls are only
    /// 79–231 px tall, which cannot be presented legibly on a desktop.
    var minimumShortEdge = 600
    var minimumLongEdge = 1600
    /// Width / height limits. Wider or taller works would become a thin sliver on screen.
    var aspectRatioRange: ClosedRange<Double> = 0.25...4.0
    /// Text shorter than this (after removing markup) isn't treated as an explanation.
    var minimumTextLength = 40

    func evaluate(_ record: CMARecord) -> Result<Artwork, Rejection> {
        if scope == .highlights && record.isHighlight != true {
            return .failure(.notHighlight)
        }
        guard let license = record.shareLicenseStatus,
              license.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("CC0") == .orderedSame
        else { return .failure(.notCC0) }

        guard let image = Self.imageRef(record.images?.print) else { return .failure(.missingImage) }
        guard image.shortestEdge >= minimumShortEdge, image.longestEdge >= minimumLongEdge else {
            if image.aspectRatio > aspectRatioRange.upperBound || image.aspectRatio < aspectRatioRange.lowerBound {
                return .failure(.extremeAspectRatio)
            }
            return .failure(.imageTooSmall)
        }
        guard aspectRatioRange.contains(image.aspectRatio) else { return .failure(.extremeAspectRatio) }

        let tombstone = record.tombstone.map(MuseumTextFormatter.plainText(fromHTML:))
        var texts: [MuseumText] = []
        for field in MuseumText.Field.preferenceOrder {
            guard let raw = record.rawText(for: field) else { continue }
            let runs = MuseumTextFormatter.runs(fromHTML: raw)
            let plain = runs.map(\.text).joined()
            // Catalog metadata is not an explanation, even if it appears in a text field.
            guard plain.count >= minimumTextLength, plain != tombstone else { continue }
            guard !texts.contains(where: { $0.plainText == plain }) else { continue }
            texts.append(MuseumText(field: field, runs: runs))
        }
        guard let primary = texts.first else { return .failure(.missingText) }

        let title = record.title.map(MuseumTextFormatter.plainText(fromHTML:)) ?? ""
        let creators = record.creators
            .compactMap { $0.description.map(MuseumTextFormatter.plainText(fromHTML:)) }
            .filter { !$0.isEmpty }

        return .success(Artwork(
            id: record.id,
            accessionNumber: record.accessionNumber?.nonEmpty,
            title: title.isEmpty ? "Untitled" : title,
            creationDate: record.creationDate.map(MuseumTextFormatter.plainText(fromHTML:))?.nonEmpty,
            creators: creators,
            culture: record.culture.first.map(MuseumTextFormatter.plainText(fromHTML:))?.nonEmpty,
            technique: record.technique?.nonEmpty,
            type: record.type?.nonEmpty,
            department: record.department?.nonEmpty,
            creditLine: record.creditline.map(MuseumTextFormatter.plainText(fromHTML:))?.nonEmpty,
            tombstone: tombstone?.nonEmpty,
            collectionURL: record.url.flatMap(Self.httpsURL),
            isHighlight: record.isHighlight == true,
            licenseStatus: "CC0",
            primaryText: primary,
            additionalTexts: Array(texts.dropFirst()),
            image: image,
            previewImage: Self.imageRef(record.images?.web)
        ))
    }

    static func imageRef(_ image: CMAImage?) -> ArtworkImageRef? {
        guard let image,
              let urlString = image.url,
              let url = httpsURL(urlString),
              let width = image.width, let height = image.height,
              width > 0, height > 0
        else { return nil }
        let ext = url.pathExtension.lowercased()
        // Never pick the multi-hundred-megabyte TIFF masters.
        guard ext == "jpg" || ext == "jpeg" else { return nil }
        return ArtworkImageRef(url: url, width: width, height: height, fileSize: image.filesize)
    }

    static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
