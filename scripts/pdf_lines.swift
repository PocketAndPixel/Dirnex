// Prints a PDF's text a line at a time, each piece of a line with the x position it starts at, for
// scripts that read tables out of a specification (scripts/generate_dts_tables.py).
//
// Usage: xcrun swift scripts/pdf_lines.swift <file.pdf>
//
// PDFKit's plain `string` runs a table's columns into one another; its line selections keep a row
// together, and the x position says which column a piece belongs to. Each page starts with
// `=====PAGE n=====`, and each row is its pieces left to right as `text@x`, joined by ` | `.

import Foundation
import PDFKit

guard CommandLine.arguments.count == 2,
      let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))
else {
    FileHandle.standardError.write(Data("usage: pdf_lines.swift <file.pdf>\n".utf8))
    exit(1)
}

struct Piece {
    let text: String
    let x: CGFloat
    let y: CGFloat
}

for index in 0..<document.pageCount {
    guard let page = document.page(at: index),
          let selection = page.selection(for: page.bounds(for: .mediaBox))
    else { continue }
    print("=====PAGE \(index + 1)=====")
    var pieces: [Piece] = []
    for line in selection.selectionsByLine() {
        let bounds = line.bounds(for: page)
        let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { pieces.append(Piece(text: text, x: bounds.minX, y: bounds.midY)) }
    }
    // Top to bottom, and pieces within 2 pt of one height are one row.
    pieces.sort { abs($0.y - $1.y) > 2 ? $0.y > $1.y : $0.x < $1.x }
    var rows: [[Piece]] = []
    for piece in pieces {
        if let row = rows.last, abs(row[0].y - piece.y) <= 2 {
            rows[rows.count - 1].append(piece)
        } else {
            rows.append([piece])
        }
    }
    for row in rows {
        print(row.sorted { $0.x < $1.x }.map { "\($0.text)@\(Int($0.x))" }.joined(separator: " | "))
    }
}
