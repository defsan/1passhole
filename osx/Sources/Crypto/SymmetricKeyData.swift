import Foundation
import CryptoKit

/// Wrapper around CryptoKit's SymmetricKey that can be passed through SwiftUI's environment.
struct SymmetricKeyData: Sendable {
    private let rawBytes: Data

    init(key: SymmetricKey) {
        self.rawBytes = key.withUnsafeBytes { Data($0) }
    }

    init(data: Data) {
        self.rawBytes = data
    }

    var symmetricKey: SymmetricKey {
        SymmetricKey(data: rawBytes)
    }

    var data: Data { rawBytes }

    func zeroed() -> Bool {
        rawBytes.allSatisfy { $0 == 0 }
    }
}
