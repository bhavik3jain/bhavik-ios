import Foundation

/// Minimal RFC 4180 style CSV reader.
///
/// Quote awareness is essential here: exported logs quote fields that contain
/// their own commas, such as `"37,057"` odometer readings and `"$6,405.36"`
/// costs, which naive splitting would tear apart.
enum CSVParser {
    static func rows(from text: String) -> [[String]] {
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
            case "\n":
                endRow()
            case "\r":
                break  // Handled by the following \n in CRLF files.
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
