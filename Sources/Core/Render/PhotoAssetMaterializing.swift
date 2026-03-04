import Foundation

public protocol PhotoAssetMaterializing: Sendable {
    func materializePhotoAsset(localIdentifier: String, preferredFilename: String) async throws -> URL
}
