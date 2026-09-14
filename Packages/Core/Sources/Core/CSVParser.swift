import Foundation

/// Minimal RFC 4180 style CSV reader.
///
/// Quote awareness is essential here: exported logs quote fields that contain
/// their own commas, such as `"37,057"` odometer readings and `"$6,405.36"`
/// costs, which naive splitting would tear apart.
public enum CSVParser {
    public static func rows(from text: String) -> [[String]] {
        // Exports written on Windows start with a UTF-8
        // byte order mark. Left in place it becomes part of the first
        // header's name, so every lookup against that column misses.
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text

        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }

        func endRow() {
            endField()
            // Skip blank trailing lines.
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil

            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")  // Escaped quote inside a quoted field.
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
            case ",":
                endField()
            // Swift folds CRLF into a single Character, so "\r\n" matches
            // neither "\r" nor "\n" and has to be named outright. Miss it and
            // a Windows-style export never ends a row: the entire file arrives
            // as one enormous field.
            case "\n", "\r\n", "\r":
                endRow()
            default:
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            endRow()
        }

        return rows
    }
}
