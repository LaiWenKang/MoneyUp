import Foundation

indirect enum CloudBackupJSON: Codable, Equatable, Sendable {
    case object([String: CloudBackupJSON]), array([CloudBackupJSON])
    case string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int64.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([String: Self].self) { self = .object(result) }
        else { self = .array(try value.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(result): try value.encode(result)
        case let .array(result): try value.encode(result)
        case let .string(result): try value.encode(result)
        case let .integer(result): try value.encode(result)
        case let .number(result): try value.encode(result)
        case let .bool(result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> Self {
        guard case let .object(values) = self else { return .null }
        return values[key] ?? .null
    }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var integer: Int64? { if case let .integer(value) = self { value } else { nil } }
    var array: [Self]? { if case let .array(value) = self { value } else { nil } }
    var object: [String: Self]? { if case let .object(value) = self { value } else { nil } }
    static func field(_ value: Self, type: String? = nil) -> Self {
        var object = ["value": value]
        if let type { object["type"] = .string(type) }
        return .object(object)
    }
}
