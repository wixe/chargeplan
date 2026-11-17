import Foundation
import Darwin

public final class ConfigManager {
    public static let shared = ConfigManager()

    private struct FileStamp: Equatable {
        let path: String
        let mtimeSec: Int
        let mtimeNsec: Int
        let size: off_t
    }

    private let systemConfigPath = ChargePlanLayout.systemConfigPath
    private let legacyConfigPath = ChargePlanLayout.legacyConfigPath
    private let userConfigPath: String
    private let lock = NSLock()
    private var cachedStamp: FileStamp?
    private var cachedConfig: GovernorConfig?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.userConfigPath = ChargePlanLayout.userConfigPath(home: home)
    }

    private static func fileStamp(for path: String) -> FileStamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileStamp(
            path: path,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            size: st.st_size
        )
    }

    private var activeReadPathAndStamp: (path: String, stamp: FileStamp)? {
        for candidate in [systemConfigPath, legacyConfigPath, userConfigPath] {
            if let stamp = Self.fileStamp(for: candidate) {
                return (candidate, stamp)
            }
        }
        return nil
    }

    private var activeWritePath: String {
        if Self.fileStamp(for: systemConfigPath) != nil {
            return systemConfigPath
        }
        if Self.fileStamp(for: legacyConfigPath) != nil {
            return legacyConfigPath
        }
        if access("/etc", W_OK) == 0 {
            return systemConfigPath
        }
        return userConfigPath
    }

    public func load() -> GovernorConfig {
        guard let (path, stamp) = activeReadPathAndStamp else {
            lock.lock()
            cachedStamp = nil
            cachedConfig = nil
            lock.unlock()
            return .default
        }

        lock.lock()
        if cachedStamp == stamp, let cached = cachedConfig {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let decoded: GovernorConfig = autoreleasepool {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let cfg = try? JSONDecoder().decode(GovernorConfig.self, from: data) else {
                return .default
            }
            return cfg
        }

        lock.lock()
        cachedStamp = stamp
        cachedConfig = decoded
        lock.unlock()
        return decoded
    }

    public func save(_ config: GovernorConfig) -> Bool {
        let path = activeWritePath
        let url = URL(fileURLWithPath: path)

        let ok: Bool = autoreleasepool {
            do {
                let parentDir = url.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(config)
                try data.write(to: url, options: .atomic)
                if path == systemConfigPath {
                    chmod(systemConfigPath, 0o644)
                }
                return true
            } catch {
                return false
            }
        }

        if ok {
            lock.lock()
            cachedStamp = Self.fileStamp(for: path)
            cachedConfig = config
            lock.unlock()
        }
        return ok
    }
}
