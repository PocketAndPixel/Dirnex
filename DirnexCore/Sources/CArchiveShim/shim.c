// This target exists for its header: `include/shim.h` declares the system libarchive entry points
// that the SDK ships a link stub for but no header. SwiftPM requires a C target to carry at least
// one source file, and including the header gives this translation unit its declarations.
//
// Nothing is *defined* here on purpose. A wrapper written in C would be a second place for the
// encryption logic to live, untested by `swift test`; every line above the raw calls belongs in
// `LibArchive.swift` and its neighbours, where it has coverage.

#include "include/shim.h"
