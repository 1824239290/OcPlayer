import Foundation
struct Number:Decodable {let value:Int64}
struct Stamp:Decodable {let value:Date}
let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
for json in ["{\"value\":1,\"value\":2}","{\"value\":-0.0}","{\"value\":9007199254740993.0}","{\"value\":-9223372036854775808}","{\"value\":9223372036854775000.0}"] {
 print("int",json,(try? d.decode(Number.self,from:Data(json.utf8)))?.value as Any)
}
for text in ["2026-01-00T00:00:00Z","2026-01-32T00:00:00Z","2026-13-01T00:00:00Z","2026-00-01T00:00:00Z","2026-01-01T25:00:00Z","2026-01-01T00:61:00Z","2026-01-01T00:00:61Z","2026-01-01t00:00:00z","2026-01-01T00:00:00","20260101T000000Z","2026-1-1T0:0:0Z"," 2026-01-01T00:00:00Z","2026-01-01T00:00:00Z ","2026-01-01T00:00:00Zextra","2026-01-01T00:00:00,5Z","2026-01-01T00:00:00.123456789Z","2026-01-01T00:00:00+08","2026-01-01T00:00:00+25:99","0000-01-01T00:00:00Z"] {
 let json="{\"value\":\"\(text)\"}";print("date",text,(try? d.decode(Stamp.self,from:Data(json.utf8)))?.value.timeIntervalSince1970 as Any)
}
