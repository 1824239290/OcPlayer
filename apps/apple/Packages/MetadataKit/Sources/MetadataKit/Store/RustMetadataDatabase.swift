import Foundation
import OcPlayerCore

/// Core owns opening/migration/rebuild and the fixed Media.sqlite sidecar scope.
/// The GRDB pool remains the compatible native adapter for the store API.
struct RustMetadataDatabase {
  let core: OcpCoreClient
  static func make(libraryPath: String? = nil, enabled: Bool = true) -> Self? {
    guard enabled, libraryPath != nil || OcpCoreFeature.isEnabled else { return nil }
    do { return Self(core: try OcpCoreClient(libraryPath: libraryPath)) } catch {
      MetadataLog.logger.warning("Core 媒体建库不可用", fields: ["error": .string("\(error)")])
      return nil
    }
  }
  struct Opened: Decodable {
    let path: String
    let rebuilt: Bool
    let firstError: String?
  }
  func call<T: Decodable>(_ method: String, at directory: URL, as type: T.Type = T.self) throws -> T
  {
    let response = try core.call(
      "metadataDatabase." + method, arguments: ["directory": directory.path])
    guard response.ok else {
      throw NSError(
        domain: "OcPlayerCore.Database", code: Int(response.code),
        userInfo: [NSLocalizedDescriptionKey: response.message])
    }
    return try response.decodeData(type)
  }
  func open(at directory: URL) throws -> Opened { try call("open", at: directory) }
  func size(at directory: URL) throws -> Int64 { try call("size", at: directory) }
  func remove(at directory: URL) {
    _ = try? core.call("metadataDatabase.remove", arguments: ["directory": directory.path])
  }
}
