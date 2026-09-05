import Foundation

/// The managed-settings approval gate the headless path waives (`deferred_non_interactive`, parent §6.12, A-48).
/// afleet refuses to spawn while a payload is pending and tells the user to open `claude` in a terminal once.
///
/// **Delegated unknown.** The consent record's shape is unrecorded in the corpus: no fixture holds one, and none can
/// be produced without a managed deployment. The reader is written from the bundle's chapter 48 §2.9 as the child
/// spec's *Preconditions* section and its *Delegated unknowns* list describe, it prefers an `approvedHash` key and
/// falls back to any string field that equals the payload's hash, and it fails closed: an unparseable pair, an
/// unreadable consent file or a hash that does not match all mean pending.
public enum ManagedSettingsReader {
    public static func isPending(configHome: URL) -> Bool {
        guard let payload = try? Data(contentsOf: configHome.appending(path: "remote-settings.json")) else {
            return false
        }
        guard let consent = try? Data(contentsOf: configHome.appending(path: "remote-settings-consent.json")),
              let record = (try? JSONSerialization.jsonObject(with: consent)) as? [String: Any] else {
            return true
        }
        let expected = ContentHash.sha256Hex(payload)
        if let approved = record["approvedHash"] as? String { return approved != expected }
        return !record.values.contains { ($0 as? String) == expected }
    }
}
