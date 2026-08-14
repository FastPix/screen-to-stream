import Foundation

/// A dynamic JSON value — MCP params/results are heterogeneous, so a fixed Codable won't do.
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] } else { return nil }
    }
    static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}

public enum RPCID: Codable, Equatable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct RPCRequest: Decodable {
    public let jsonrpc: String
    public let id: RPCID?
    public let method: String
    public let params: JSONValue?

    public init(jsonrpc: String, id: RPCID?, method: String, params: JSONValue?) {
        self.jsonrpc = jsonrpc; self.id = id; self.method = method; self.params = params
    }
}

public struct RPCResponse: Encodable {
    public let jsonrpc = "2.0"
    public let id: RPCID?
    public var result: JSONValue?
    public var error: RPCError?

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    static func success(id: RPCID?, _ result: JSONValue) -> RPCResponse {
        RPCResponse(id: id, result: result, error: nil)
    }
    static func failure(id: RPCID?, code: Int, _ message: String) -> RPCResponse {
        RPCResponse(id: id, result: nil, error: RPCError(code: code, message: message))
    }
}

public struct RPCError: Encodable {
    public let code: Int
    public let message: String
}

/// MCP stdio framing: one JSON object per line, `\n` terminated.
public enum Framing {
    public static func encode(_ response: RPCResponse) -> Data {
        var data = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Pulls the first complete newline-terminated message out of `buffer`, removing it (and the
    /// newline) from the buffer. Returns nil when there is no complete line yet.
    public static func decode(from buffer: inout Data) -> RPCRequest? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)

        guard !line.isEmpty else { return decode(from: &buffer) }   // skip blank lines
        return try? JSONDecoder().decode(RPCRequest.self, from: Data(line))
    }
}
