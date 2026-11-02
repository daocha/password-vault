import Foundation

/// Keep subsecond edits distinguishable from a backup snapshot, as Android's Instant timestamps do.
public enum VaultTimestamp {
    public static func format(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
