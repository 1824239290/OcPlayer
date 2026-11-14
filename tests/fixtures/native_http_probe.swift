import Foundation
let semaphore = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: URL(string: CommandLine.arguments[1])!) { data, response, error in
    let http = response as? HTTPURLResponse
    let result: [String: Any] = [
        "status": http?.statusCode ?? 0,
        "bodyBase64": (data ?? Data()).base64EncodedString(),
        "encoding": http?.value(forHTTPHeaderField: "Content-Encoding") ?? "",
        "length": http?.value(forHTTPHeaderField: "Content-Length") ?? "",
        "error": error != nil,
    ]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    semaphore.signal()
}.resume()
if semaphore.wait(timeout: .now() + 10) == .timedOut { exit(2) }
