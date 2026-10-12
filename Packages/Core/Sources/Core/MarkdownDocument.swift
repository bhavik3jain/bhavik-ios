import Foundation
import SwiftUI

/// A Markdown file read as a list of blocks, so a document bundled with the
/// app (the privacy policy in Settings) can be shown as a native page.
///
/// Only the handful of block types that document uses: `#` title, `##`
/// headings, `-` bullets and paragraphs, each a run of lines up to a blank
/// one. Links and emphasis stay inline Markdown for `MarkdownDocumentView`.
/// `Text` only renders inline Markdown: handed the whole file, it shows the
/// `#`s and `-`s as typed, or, parsed in full, runs every heading, bullet
/// and paragraph together into one block.
public struct MarkdownDocument: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case title(String)
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    public let blocks: [Block]

    public init(_ markdown: String) {
        blocks = Self.parse(markdown)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullet: [String]?

        func flush() {
            if let lines = bullet {
                blocks.append(.bullet(lines.joined(separator: " ")))
            } else if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
            }
            bullet = nil
            paragraph = []
        }

        // `isNewline` rather than splitting on "\n": a CRLF file's "\r\n" is
        // one Character in Swift, so this reads it the same as LF.
        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, line.dropFirst(hashes).first == " " {
                flush()
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(hashes == 1 ? .title(text) : .heading(text))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                bullet = [line.dropFirst(2).trimmingCharacters(in: .whitespaces)]
                continue
            }
            if bullet != nil {
                bullet?.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// `MarkdownDocument` laid out as a reading page: links open in the
/// browser, text can be selected and copied.
public struct MarkdownDocumentView: View {
    private let document: MarkdownDocument

    public init(_ document: MarkdownDocument) {
        self.document = document
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .title(let text):
                    Text(Self.inline(text))
                        .font(.title.bold())
                case .heading(let text):
                    Text(Self.inline(text))
                        .font(.title3.weight(.semibold))
                        .padding(.top, 8)
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•")
                            .foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
