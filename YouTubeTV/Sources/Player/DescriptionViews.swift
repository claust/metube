import CoreImage.CIFilterBuiltins
import SwiftUI

/// YouTube's dark-theme link blue.
private let linkColor = Color(red: 0.24, green: 0.65, blue: 1.0)

// MARK: - Text

/// One focusable block of a description, with its links tinted.
struct DescriptionParagraph: Identifiable {
    let id: Int
    let text: AttributedString
}

extension VideoDescription {
    /// The most a row may hold, in UTF-16 units and in lines. Each block is its own focusable
    /// row because focus is what scrolls on tvOS, so a row taller than the panel would never show
    /// its end. Both limits are needed: 500 units of prose wraps to about a dozen lines at the
    /// card's 24pt in the 560pt-wide column, while a chapter list of short `00:00 Intro` lines
    /// can run to forty lines inside the same 500.
    static let maxBlockLength = 500
    static let maxBlockLines = 10

    /// The description cut at blank lines, with any block still too long for one row cut again
    /// — see `chunks(of:)`.
    var paragraphs: [DescriptionParagraph] {
        let whole = text as NSString
        let breaks =
            (try? NSRegularExpression(pattern: "\\n\\s*\\n"))?
            .matches(in: text, range: NSRange(location: 0, length: whole.length)) ?? []
        var ranges: [NSRange] = []
        var start = 0
        for match in breaks {
            ranges.append(NSRange(location: start, length: match.range.location - start))
            start = match.range.location + match.range.length
        }
        ranges.append(NSRange(location: start, length: whole.length - start))
        return ranges.flatMap(chunks).filter { $0.length > 0 }.map {
            DescriptionParagraph(id: $0.location, text: attributed($0))
        }
    }

    /// `range` in pieces of at most `maxBlockLength` units and `maxBlockLines` lines, cut at the
    /// last line break that fits, else the last sentence end, else the last space — a chapter list
    /// stays whole lines and prose whole sentences. A cut avoids landing inside a link, unless the
    /// link alone is longer than a row.
    private func chunks(of range: NSRange) -> [NSRange] {
        let whole = text as NSString
        var pieces: [NSRange] = []
        var start = range.location
        let end = range.location + range.length
        while true {
            let lineLimit = endOfLines(from: start, before: end)
            guard end - start > Self.maxBlockLength || lineLimit != nil else { break }
            var cut = start + Self.maxBlockLength
            if let lineLimit, lineLimit - start <= Self.maxBlockLength {
                cut = lineLimit
            } else {
                let window = NSRange(location: start, length: Self.maxBlockLength)
                for separator in ["\n", ". ", " "] {
                    let found = whole.range(of: separator, options: .backwards, range: window)
                    if found.location != NSNotFound, found.location > start {
                        cut = found.location + found.length
                        break
                    }
                }
            }
            if let link = links.first(where: { $0.range.location < cut && cut < NSMaxRange($0.range) }),
                link.range.location > start
            {
                cut = link.range.location
            }
            // Never between the halves of a surrogate pair or inside a composed emoji.
            cut = whole.rangeOfComposedCharacterSequence(at: cut).location
            if cut <= start {
                cut = NSMaxRange(whole.rangeOfComposedCharacterSequence(at: start + Self.maxBlockLength - 1))
            }
            // The whitespace either side of the cut belongs to neither row.
            var pieceEnd = cut
            while pieceEnd > start, isSpace(at: pieceEnd - 1) { pieceEnd -= 1 }
            pieces.append(NSRange(location: start, length: pieceEnd - start))
            start = cut
            while start < end, isSpace(at: start) { start += 1 }
        }
        pieces.append(NSRange(location: start, length: end - start))
        return pieces
    }

    /// Just past the `maxBlockLines`-th line break after `start`, when that falls before `end` —
    /// that is, where a row must end for its lines to fit. `nil` when they already do.
    private func endOfLines(from start: Int, before end: Int) -> Int? {
        let whole = text as NSString
        var location = start
        for _ in 0..<Self.maxBlockLines {
            let found = whole.range(of: "\n", range: NSRange(location: location, length: end - location))
            guard found.location != NSNotFound else { return nil }
            location = NSMaxRange(found)
        }
        return location < end ? location : nil
    }

    private func isSpace(at index: Int) -> Bool {
        guard let scalar = Unicode.Scalar((text as NSString).character(at: index)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func attributed(_ range: NSRange) -> AttributedString {
        let piece = (text as NSString).substring(with: range)
        var result = AttributedString(piece)
        // The part of each link inside this block: a link longer than a whole row (see
        // `chunks(of:)`) is split across rows, and each half still reads as a link.
        for link in links {
            let overlap = NSIntersectionRange(link.range, range)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - range.location, length: overlap.length)
            guard let bounds = Range(local, in: piece),
                let lower = AttributedString.Index(bounds.lowerBound, within: result),
                let upper = AttributedString.Index(bounds.upperBound, within: result)
            else { continue }
            result[lower..<upper].foregroundColor = linkColor
        }
        return result
    }
}

extension DescriptionLink {
    /// "linktr.ee/rickastleynever" rather than the full URL with its scheme.
    var shortDisplay: String {
        guard case .web(let url) = kind, let host = url.host() else { return display }
        let path = url.path() == "/" ? "" : url.path()
        return host.replacingOccurrences(of: "www.", with: "") + path
    }
}

// MARK: - Pieces

/// Title, then channel · views · age.
struct DescriptionHeader: View {
    let description: VideoDescription
    var titleLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(description.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(titleLines)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                [description.channel, description.viewCount, description.publishedTime]
                    .filter { !$0.isEmpty }.joined(separator: "  ·  ")
            )
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
        }
    }
}

/// One paragraph as a quiet focusable row: no chrome until focused, so it reads as text.
struct DescriptionParagraphRow: View {
    let paragraph: DescriptionParagraph

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
        } label: {
            Text(paragraph.text)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(isFocused ? 0.16 : 0)))
        }
        .buttonStyle(CommentRowButtonStyle())
        .focused($isFocused)
    }
}

/// An outside link. Focused, it grows a QR code so the viewer can open it on their phone —
/// a TV has no browser to send it to.
struct DescriptionLinkRow: View {
    let link: DescriptionLink

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "link")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(linkColor)
                    Text(link.shortDisplay)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(isFocused ? .white : linkColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isFocused, case .web(let url) = link.kind {
                    HStack(alignment: .center, spacing: 22) {
                        QRCodeView(text: url.absoluteString)
                            .frame(width: 200, height: 200)
                        Text("Scan with your phone\nto open this link")
                            .font(.system(size: 21))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.2 : 0.06)))
        }
        .buttonStyle(CommentRowButtonStyle())
        .focused($isFocused)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A crisp QR code on a white tile, sized by whatever frame it is given.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The description's card at the top of the comments list: a three-line preview. Select
/// unfolds the rest below it as ordinary rows, so the list keeps scrolling the way it does.
struct PinnedDescriptionCard: View {
    let description: VideoDescription
    let isExpanded: Bool
    let toggle: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 12) {
                DescriptionHeader(description: description, titleLines: 2)
                if !isExpanded {
                    Text(description.paragraphs.first?.text ?? "")
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                }
                Label(
                    isExpanded ? "Show less" : "Show more",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                )
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(isFocused ? 1 : 0.6))
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.24 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(CommentRowButtonStyle())
        .focused($isFocused)
    }
}
