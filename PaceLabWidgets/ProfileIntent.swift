import AppIntents
import WidgetKit

/// A Pace Lab profile, as offered in the widget's configuration.
struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static let defaultQuery = ProfileQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The profiles the app last passed on to the widgets.
struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        all()
    }

    private func all() -> [ProfileEntity] {
        SnapshotStore.loadProfiles()?.profiles.map { ProfileEntity(id: $0.id, name: $0.name) } ?? []
    }
}

/// Whose training a widget shows. Without a choice: the profile that is active in Pace Lab.
struct SelectProfileIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Profile"
    static let description = IntentDescription("Choose whose training the widget shows.")

    @Parameter(title: "Profile", description: "Empty: the profile that is active in Pace Lab.")
    var profile: ProfileEntity?

    init() {}
}
