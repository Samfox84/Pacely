import Foundation

/// Plans kept on this Mac: one file, plus a backup copy each day (the last 14 are kept).
enum LocalStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pacely", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("pacely-data.json") }
    static var backupsFolder: URL { folder.appendingPathComponent("Backups", isDirectory: true) }

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func read() -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    static func write(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Pacely could not save: \(error)")
        }
        dailyBackup()
    }

    private static func stamp(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }

    static func dailyBackup() {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        let target = backupsFolder.appendingPathComponent("pacely-\(stamp("yyyy-MM-dd")).json")
        if !fm.fileExists(atPath: target.path) {
            try? fm.copyItem(at: file, to: target)
            prune()
        }
    }

    /// A copy made just before something big, like replacing everything from a file.
    static func safetyCopy(_ reason: String) {
        guard exists else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        try? fm.copyItem(at: file, to: backupsFolder.appendingPathComponent("pacely-\(stamp("yyyy-MM-dd-HHmmss"))-\(reason).json"))
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil) else { return }
        let daily = files.filter { $0.lastPathComponent.range(of: #"^pacely-\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in daily.dropFirst(14) { try? fm.removeItem(at: old) }
    }

    /// Returns the file's text if it looks like a Pacely backup (including ones from early test versions).
    static func validBackup(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let app = obj["app"] as? String ?? ""
        guard ["pacely", "tempo"].contains(app) || obj["activities"] is [Any] else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
