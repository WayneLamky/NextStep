import Foundation
import SwiftData

@MainActor
final class AppStore {
    static let shared = AppStore()

    let container: ModelContainer

    private init() {
        let schema = Schema([Project.self, TempTask.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }

    var context: ModelContext { container.mainContext }
}
