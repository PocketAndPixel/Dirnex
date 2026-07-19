#!/usr/bin/env swift
import Foundation

// generate-fixtures.swift — builds nasty test directory trees for Dirnex.
//
// The point is to exercise the panel and the core against the inputs that break
// naive file managers: deep nesting, huge directories, and pathological names
// (emoji, NFC vs NFD unicode, very long names, spaces/newlines, symlinks and
// broken symlinks). DirnexCore tests and manual M1 browsing both point here.
//
// Usage:
//   swift Tooling/generate-fixtures.swift [outdir] [--huge] [--count N]
//
//   outdir     Destination root (default: ./.fixtures). Wiped and recreated.
//   --huge     Also generate a 100k-entry flat directory (slow; off by default).
//   --count N  Entries in the "many" directory when not --huge (default: 2000).
//
// Exit code is non-zero on failure so CI can gate on it.

struct Options {
    var outDir = "./.fixtures"
    var huge = false
    var manyCount = 2000
}

func parseOptions() -> Options {
    var opts = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--huge":
            opts.huge = true
        case "--count":
            index += 1
            guard index < args.count, let value = Int(args[index]), value > 0 else {
                fail("--count requires a positive integer")
            }
            opts.manyCount = value
        case "-h", "--help":
            print("""
            Usage: swift Tooling/generate-fixtures.swift [outdir] [--huge] [--count N]
            """)
            exit(0)
        default:
            if arg.hasPrefix("-") { fail("unknown flag: \(arg)") }
            opts.outDir = arg
        }
        index += 1
    }
    return opts
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let fm = FileManager.default

func makeDir(_ path: String) {
    do {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    } catch {
        fail("mkdir \(path): \(error.localizedDescription)")
    }
}

func writeFile(_ path: String, bytes: Int = 0, contents: String? = nil) {
    let data: Data
    if let contents {
        data = Data(contents.utf8)
    } else if bytes > 0 {
        data = Data(repeating: UInt8(ascii: "x"), count: bytes)
    } else {
        data = Data()
    }
    if !fm.createFile(atPath: path, contents: data) {
        fail("write \(path)")
    }
}

func symlink(_ linkPath: String, to target: String) {
    do {
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    } catch {
        fail("symlink \(linkPath) -> \(target): \(error.localizedDescription)")
    }
}

let opts = parseOptions()
let root = (opts.outDir as NSString).expandingTildeInPath

// Start fresh so runs are reproducible.
if fm.fileExists(atPath: root) {
    do { try fm.removeItem(atPath: root) }
    catch { fail("clean \(root): \(error.localizedDescription)") }
}

makeDir(root)

// 1. A plain, friendly directory.
let plain = root + "/plain"
makeDir(plain)
for i in 1...20 {
    writeFile(plain + "/file-\(String(format: "%03d", i)).txt", contents: "hello \(i)\n")
}

makeDir(plain + "/subfolder")
writeFile(plain + "/subfolder/readme.md", contents: "# Subfolder\n")

// 2. Deep nesting (100 levels, short segments so the total path stays well
//    under PATH_MAX regardless of how long `root` is).
var deep = root + "/deep"
makeDir(deep)
for level in 1...100 {
    deep += "/d\(level)"
    makeDir(deep)
}

writeFile(deep + "/bottom.txt", contents: "you made it\n")

// 2b. A deliberately long path (~1000 chars) built from many segments, since a
//     single component can't exceed NAME_MAX (255). Grow greedily but stop
//     before PATH_MAX so this works even when `root` is already long.
let pathMax = 1024
let longPathCeiling = min(1000, pathMax - 64) // leave room for a filename
var longPath = root + "/long-path"
makeDir(longPath)
let segment = "/" + String(repeating: "n", count: 40)
while longPath.utf8.count + segment.utf8.count < longPathCeiling {
    longPath += segment
    makeDir(longPath)
}

writeFile(longPath + "/leaf.txt", contents: "deep in a long path\n")

// 3. Pathological names.
let weird = root + "/weird-names"
makeDir(weird)
let weirdNames: [String] = [
    "emoji 🗂️📁🔥.txt",
    "with spaces and    tabs.txt",
    "with\nnewline.txt", // newline in filename
    "café-NFC.txt", // é as single precomposed scalar (U+00E9)
    "cafe\u{0301}-NFD.txt", // e + combining acute accent
    "UPPER.TXT",
    "upper.txt", // case-only sibling difference
    ".hidden-dotfile",
    "trailing.dots...",
    "-leading-dash.txt",
    "quote'and\"double.txt",
    String(repeating: "long", count: 60) + ".txt" // ~240-char name
]
for name in weirdNames {
    writeFile(weird + "/" + name, contents: "weird\n")
}

// 4. Symlinks: valid file, valid dir, broken, and absolute.
let links = root + "/symlinks"
makeDir(links)
writeFile(links + "/target.txt", contents: "real file\n")
symlink(links + "/link-to-file", to: "target.txt")
symlink(links + "/link-to-dir", to: "../plain")
symlink(links + "/broken-link", to: "does-not-exist.txt")
symlink(links + "/absolute-link", to: root + "/plain/subfolder")

// 5. Mixed sizes for sort/size testing.
let sizes = root + "/sizes"
makeDir(sizes)
writeFile(sizes + "/empty.bin", bytes: 0)
writeFile(sizes + "/tiny.bin", bytes: 1)
writeFile(sizes + "/kilobyte.bin", bytes: 1024)
writeFile(sizes + "/megabyte.bin", bytes: 1024 * 1024)

// 6. Large flat directory. Modest by default; 100k under --huge.
let many = root + "/many"
makeDir(many)
let manyCount = opts.huge ? 100_000 : opts.manyCount
let width = String(manyCount).count
for i in 0..<manyCount {
    writeFile(many + "/entry-\(String(format: "%0\(width)d", i)).dat", bytes: 0)
}

print("Fixtures written to \(root)")
print("  plain/         friendly files + one subfolder")
print("  deep/          100 levels of nesting")
print("  weird-names/   emoji, NFC/NFD, long, spaces, case-collisions")
print("  symlinks/      valid / broken / absolute links")
print("  sizes/         empty..1MB for sort tests")
print("  many/          \(manyCount) flat entries\(opts.huge ? " (huge)" : "")")
