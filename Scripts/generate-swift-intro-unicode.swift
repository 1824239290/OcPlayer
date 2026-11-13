import Foundation
func ranges(_ predicate: (Unicode.Scalar) -> Bool) -> [(UInt32, UInt32)] {
    var result: [(UInt32, UInt32)] = []
    var start: UInt32?
    var previous: UInt32 = 0
    for value in UInt32(0)...UInt32(0x10FFFF) {
        let matches = Unicode.Scalar(value).map(predicate) ?? false
        if matches { if start == nil { start = value }; previous = value }
        else if let low = start { result.append((low, previous)); start = nil }
    }
    if let low = start { result.append((low, previous)) }
    return result
}
print("//! Scalar tables derived from the reference Swift runtime for intro parsing.")
print("//! Generated with Scripts/generate-swift-intro-unicode.swift; do not edit by hand.")
for (name, predicate) in [("NUMERIC", { (s: Unicode.Scalar) in Character(String(s)).isNumber }),
                          ("WHITESPACE", { (s: Unicode.Scalar) in CharacterSet.whitespaces.contains(s) })] {
    print("pub const \(name): &[(u32,u32)] = &[")
    for (low, high) in ranges(predicate) { print("    (0x\(String(low,radix:16)), 0x\(String(high,radix:16))),") }
    print("];")
}
