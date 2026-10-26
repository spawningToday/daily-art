import SwiftUI

extension MuseumText {
    /// The museum's text with its italics (titles of works) preserved.
    var attributed: AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.isItalic { part.inlinePresentationIntent = .emphasized }
            result += part
        }
        return result
    }
}

/// Exhibition-label style text for one artwork.
struct ArtworkDetailView: View {
    let artwork: Artwork
    var showsAllTexts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(artwork.attribution)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(artwork.title)
                    .font(.system(.title2, design: .serif).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let meta = metaLine {
                    Text(meta)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)

            Text(artwork.primaryText.attributed)
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if showsAllTexts {
                ForEach(extraTexts, id: \.field) { text in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text.field.heading)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(text.attributed)
                            .font(.system(.callout, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text(footer)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: String? {
        let parts = [artwork.creationDate, artwork.technique].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Did you know?" first: it's the most likely extra.
    private var extraTexts: [MuseumText] {
        artwork.additionalTexts.sorted { lhs, rhs in
            (lhs.field == .didYouKnow ? 0 : 1) < (rhs.field == .didYouKnow ? 0 : 1)
        }
    }

    private var footer: String {
        var parts = ["The Cleveland Museum of Art"]
        if let credit = artwork.creditLine { parts.append(credit) }
        if let accession = artwork.accessionNumber { parts.append(accession) }
        parts.append("CC0")
        return parts.joined(separator: " · ")
    }
}
