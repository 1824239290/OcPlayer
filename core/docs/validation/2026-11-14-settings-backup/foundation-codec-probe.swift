import Foundation
struct Number: Decodable { let value: Int64 }
struct Stamp: Decodable { let value: Date }
let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
for raw in ["1","1.0","1e0","1.5","9223372036854775807","9223372036854775807.0","9.223372036854775807e18","-9223372036854775808.0","1e100"] {
 do { let number = try decoder.decode(Number.self, from: Data("{\"value\":\(raw)}".utf8));print("int",raw,number.value) } catch { print("int",raw,"reject") }
}
for raw in ["2026-11-14T00:01:02Z","2026-11-14T00:01:02.123Z","2026-11-14T08:01:02+08:00","2026-11-14T08:01:02+0800","2026-11-14 00:01:02Z","2026-02-30T00:00:00Z","2026-11-14","2026-11-14T24:00:00Z","2026-11-14T00:00:60Z"] {
 do { let stamp = try decoder.decode(Stamp.self, from: Data("{\"value\":\"\(raw)\"}".utf8));print("date",raw,stamp.value.timeIntervalSince1970) } catch { print("date",raw,"reject") }
}
for scalar in (0...0x3000) {
 if let c=Unicode.Scalar(scalar), CharacterSet.whitespacesAndNewlines.contains(c) { print("space",String(scalar,radix:16)) }
}
for encoding in [String.Encoding.utf8,.utf16LittleEndian,.utf16BigEndian,.utf32LittleEndian,.utf32BigEndian] {
 let bytes="{\"value\":42}".data(using: encoding)!
 print("encoding",encoding.rawValue,(try? decoder.decode(Number.self,from:bytes))?.value as Any)
}
