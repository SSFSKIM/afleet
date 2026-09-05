import Foundation
import CryptoKit

/// The one hash in `FleetSessions`, and the only place `CryptoKit` is imported (Task 9's import allowlist):
/// the `.mcp.json` entry hash and the managed-settings payload hash both go through it.
public enum ContentHash {
    /// Lowercase hex of the SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
