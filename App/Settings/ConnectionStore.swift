import ChatbotCore
import Foundation
import Observation

/// 指向某个 Connection 下的一个 Model。
struct ModelRef: Codable, Hashable {
    var connectionID: UUID
    var modelID: String
}

/// Connection 列表和 Default Model，以 JSON 存在 UserDefaults（ARCHITECTURE §5.1）。API key 不在这里，在 Keychain。
@MainActor
@Observable
final class ConnectionStore {
    private static let connectionsKey = "connections"
    private static let defaultModelKey = "defaultModel"

    private let defaults: UserDefaults
    private(set) var connections: [Connection]
    var defaultModel: ModelRef? {
        didSet { Self.write(defaultModel, forKey: Self.defaultModelKey, to: defaults) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        connections = Self.read([Connection].self, forKey: Self.connectionsKey, from: defaults) ?? []
        defaultModel = Self.read(ModelRef.self, forKey: Self.defaultModelKey, from: defaults)
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    /// 新增或更新一个 Connection。还没有 Default Model 时，用它的第一个 Model。
    func save(_ connection: Connection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        Self.write(connections, forKey: Self.connectionsKey, to: defaults)
        if defaultModel == nil, let first = connection.models.first {
            defaultModel = ModelRef(connectionID: connection.id, modelID: first.id)
        }
    }

    /// 模型选择器里列出的 Model：按 Connection 分组，去掉隐藏的。
    func visibleModels(of connection: Connection) -> [ModelInfo] {
        connection.models.filter { !connection.hiddenModelIDs.contains($0.id) }
    }

    private static func read<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T?, forKey key: String, to defaults: UserDefaults) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
