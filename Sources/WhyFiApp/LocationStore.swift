import Foundation
import Observation
import WhyFiCore

/// Saved location snapshots, persisted as JSON in Application Support.
@MainActor @Observable
final class LocationStore {
    private(set) var snapshots: [LocationSnapshot] = []
    var compared: Set<UUID> = []
    private(set) var lastError: String?

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhyFi", isDirectory: true)
        return dir.appendingPathComponent("locations.json")
    }()

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            snapshots = try dec.decode([LocationSnapshot].self, from: data)
            compared = Set(snapshots.map(\.id))
        } catch {
            // Move the unreadable file aside so the next save can't overwrite the user's data.
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent().appendingPathComponent("locations.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            lastError = "Couldn't read saved locations (kept as \(aside.lastPathComponent)): \(error.localizedDescription)"
        }
    }

    func add(_ s: LocationSnapshot) {
        snapshots.append(s)
        compared.insert(s.id)
        save()
    }

    func remove(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
        compared.remove(id)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[i].name = name
        save()
    }

    var comparedSnapshots: [LocationSnapshot] { snapshots.filter { compared.contains($0.id) } }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(snapshots).write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save locations: \(error.localizedDescription)"
        }
    }
}
