import Foundation

/// Only user choices are persisted. A running session is intentionally never restored.
public struct Preferences: Codable, Equatable {
    public static let allowedDurations = Array(stride(from: 15, through: 360, by: 15))

    public var durationMinutes: Int
    public var keepScreenAwake: Bool
    public var previousDurations: [Int]

    public init(
        durationMinutes: Int = 15,
        keepScreenAwake: Bool = true,
        previousDurations: [Int] = []
    ) {
        self.durationMinutes = Self.isValidDuration(durationMinutes) ? durationMinutes : 15
        self.keepScreenAwake = keepScreenAwake
        var seen = Set<Int>()
        self.previousDurations = previousDurations.filter {
            Self.isValidDuration($0) && seen.insert($0).inserted
        }.prefix(3).map { $0 }
    }

    public static func isValidDuration(_ minutes: Int) -> Bool {
        (15...360).contains(minutes) && minutes.isMultiple(of: 15)
    }

    public func sanitized() -> Preferences {
        Preferences(
            durationMinutes: durationMinutes,
            keepScreenAwake: keepScreenAwake,
            previousDurations: previousDurations
        )
    }

    private enum CodingKeys: String, CodingKey {
        case durationMinutes, keepScreenAwake, previousDurations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            durationMinutes: (try? values.decode(Int.self, forKey: .durationMinutes)) ?? 15,
            keepScreenAwake: (try? values.decode(Bool.self, forKey: .keepScreenAwake)) ?? true,
            previousDurations: (try? values.decode([Int].self, forKey: .previousDurations)) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        let clean = sanitized()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clean.durationMinutes, forKey: .durationMinutes)
        try values.encode(clean.keepScreenAwake, forKey: .keepScreenAwake)
        try values.encode(clean.previousDurations, forKey: .previousDurations)
    }
}
