import Combine
import CoreData
import Foundation

private final class PersistentStoreLoadResult: @unchecked Sendable {
    var errorDescription: String?
}

@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [GameRecord] = []
    @Published private(set) var errorMessage: String?

    private enum Field {
        static let id = "id"
        static let startedAt = "startedAt"
        static let endedAt = "endedAt"
        static let status = "status"
        static let whitePlayer = "whitePlayer"
        static let blackPlayer = "blackPlayer"
        static let moveCount = "moveCount"
        static let payload = "payload"
    }

    private static let entityName = "StoredGame"
    private let container: NSPersistentContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "ChessnutCoachGames", managedObjectModel: model)

        if let description = container.persistentStoreDescriptions.first {
            description.shouldAddStoreAsynchronously = false
            description.type = NSSQLiteStoreType
            if inMemory {
                description.url = URL(fileURLWithPath: "/dev/null")
            } else if let storeURL {
                description.url = storeURL
            }
        }

        container.viewContext.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyObjectTrumpMergePolicyType
        )
        container.viewContext.automaticallyMergesChangesFromParent = true
        let loadResult = PersistentStoreLoadResult()
        container.loadPersistentStores { _, error in
            loadResult.errorDescription = error?.localizedDescription
        }

        if let errorDescription = loadResult.errorDescription {
            errorMessage = "No se pudo abrir la biblioteca de partidas: \(errorDescription)"
        } else {
            reload()
        }
    }

    var resumableGame: GameRecord? {
        games.first {
            $0.status == .playing && (!$0.moves.isEmpty || $0.mode == .solo)
        }
    }

    func upsert(_ game: GameRecord) {
        do {
            let payload = try encoder.encode(game)
            let object = try storedObject(id: game.id) ?? NSEntityDescription.insertNewObject(
                forEntityName: Self.entityName,
                into: container.viewContext
            )

            object.setValue(game.id, forKey: Field.id)
            object.setValue(game.startedAt, forKey: Field.startedAt)
            object.setValue(game.endedAt, forKey: Field.endedAt)
            object.setValue(game.status.rawValue, forKey: Field.status)
            object.setValue(game.whitePlayer, forKey: Field.whitePlayer)
            object.setValue(game.blackPlayer, forKey: Field.blackPlayer)
            object.setValue(Int32(game.moveCount), forKey: Field.moveCount)
            object.setValue(payload, forKey: Field.payload)

            try saveAndReload()
        } catch {
            report(error, action: "guardar la partida")
        }
    }

    func delete(_ game: GameRecord) {
        do {
            if let object = try storedObject(id: game.id) {
                container.viewContext.delete(object)
                try saveAndReload()
            }
        } catch {
            report(error, action: "borrar la partida")
        }
    }

    func reload() {
        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: Field.startedAt, ascending: false)]
            let objects = try container.viewContext.fetch(request)
            var decodedGames: [GameRecord] = []

            for object in objects {
                guard let payload = object.value(forKey: Field.payload) as? Data else { continue }
                do {
                    decodedGames.append(try decoder.decode(GameRecord.self, from: payload))
                } catch {
                    errorMessage = "Hay una partida guardada que no se pudo leer. El resto de la biblioteca sigue disponible."
                }
            }

            games = decodedGames.sorted { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    return lhs.startedAt > rhs.startedAt
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            if decodedGames.count == objects.count {
                errorMessage = nil
            }
        } catch {
            report(error, action: "cargar la biblioteca")
        }
    }

    private func storedObject(id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "%K == %@", Field.id, id as CVarArg)
        return try container.viewContext.fetch(request).first
    }

    private func saveAndReload() throws {
        if container.viewContext.hasChanges {
            try container.viewContext.save()
        }
        reload()
    }

    private func report(_ error: Error, action: String) {
        errorMessage = "No se pudo \(action): \(error.localizedDescription)"
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = entityName
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        entity.properties = [
            attribute(Field.id, type: .UUIDAttributeType, optional: false),
            attribute(Field.startedAt, type: .dateAttributeType, optional: false),
            attribute(Field.endedAt, type: .dateAttributeType, optional: true),
            attribute(Field.status, type: .stringAttributeType, optional: false),
            attribute(Field.whitePlayer, type: .stringAttributeType, optional: false),
            attribute(Field.blackPlayer, type: .stringAttributeType, optional: false),
            attribute(Field.moveCount, type: .integer32AttributeType, optional: false),
            attribute(Field.payload, type: .binaryDataAttributeType, optional: false),
        ]
        entity.uniquenessConstraints = [[Field.id]]
        model.entities = [entity]
        return model
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }
}
