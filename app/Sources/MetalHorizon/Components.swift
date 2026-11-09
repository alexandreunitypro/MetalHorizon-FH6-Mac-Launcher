import CryptoKit
import Foundation

// The pieces MetalHorizon downloads by itself: Blackwell Engine and Apple's D3DMetal (Game Porting Toolkit redist,
// distributed non-commercially under Apple's licence, which the user accepts in the app first). Each is a tarball in a
// GitHub release, pinned by SHA-256 in Resources/components.json. MH_COMPONENTS_DIR=<folder> takes the tarballs from
// a local folder instead (testing); a matching file in ~/Library/Application Support/MetalHorizon/Downloads is used first.

struct Component: Decodable {
    var id: String          // "engine", "engine-steam", "d3dmetal", "engine-native" or "wineloader"
    var name: String
    var version: String
    var url: String
    var sha256: String
    var size: Int64
    var folder: String      // the folder it becomes in ~/Library/Application Support/MetalHorizon
    var root: String        // the top folder inside the tarball
    var license: String?    // a file inside the tarball to show and have accepted before installing
    var signedBy: String?   // an app bundle's Developer ID team: the install is refused unless its signature checks out

    var destination: String { supportDirectory.appendingPathComponent(folder).path }
    /// Beside a signed bundle, never inside it: a file added to a sealed bundle breaks its signature.
    private var marker: String {
        signedBy == nil ? destination + "/.metalhorizon-component.json"
            : supportDirectory.appendingPathComponent(".\(folder).metalhorizon-component.json").path
    }

    static func all() -> [Component] {
        guard let url = Bundle.main.url(forResource: "components", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String: [Component]].self, from: data)["components"] else { return [] }
        return list
    }

    static func named(_ id: String) -> Component? { all().first { $0.id == id } }

    /// The version installed, from the marker written after a verified install.
    var installedVersion: String? {
        guard let data = FileManager.default.contents(atPath: marker),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return info["sha256"] == sha256 ? info["version"] : nil
    }
    var isInstalled: Bool { installedVersion == version }

    func writeMarker() throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "sha256": sha256, "url": url])
        try data.write(to: URL(fileURLWithPath: marker))
    }
}

enum InstallError: Error, CustomStringConvertible {
    case badChecksum(String), badArchive(String), declined, tool(String)
    var description: String {
        switch self {
        case .badChecksum(let n): return "\(n): the download does not match its SHA-256; nothing was installed."
        case .badArchive(let n): return "\(n): the archive is not laid out as expected."
        case .declined: return "Apple's licence was not accepted; D3DMetal was not installed."
        case .tool(let m): return m
        }
    }
}

/// A download error worth another try: the network, or a server error (GitHub's release host answers 502 and 504
/// for minutes at a time; measured 2026-11-05 by Highball and 2026-11-08 here).
struct RetryableDownloadError: Error, CustomStringConvertible {
    var description: String
}

/// Downloads with progress (URLSession's async download gives none).
private final class Download: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func fetch(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Up to five tries, waiting longer each time, on a network error or a 5xx; a 404 fails at once.
    static func fetchWithRetries(_ url: URL, attempts: Int = 5, progress: @escaping (Double) -> Void,
                                 note: @escaping (String) -> Void) async throws -> URL {
        var lastError: Error = RetryableDownloadError(description: "no attempt")
        for attempt in 1...attempts {
            do {
                return try await Download(progress: progress).fetch(url)
            } catch let error as RetryableDownloadError {
                lastError = error
            } catch let error as URLError where error.code != .cancelled {
                lastError = error
            }
            guard attempt < attempts else {
                // Last resort: macOS's curl, which resumes and retries on its own (issue #10: the release host kept
                // answering 504 to the app while a browser got the file).
                note("Trying another way to download…")
                if let file = curl(url) { return file }
                break
            }
            let wait = [5, 15, 30, 60][min(attempt - 1, 3)]
            note("The download server did not answer (\(lastError)); trying again in \(wait) s (\(attempt + 1) of \(attempts))…")
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
        }
        throw lastError
    }

    static func curl(_ url: URL) -> URL? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-\(UUID().uuidString)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-fsSL", "--retry", "8", "--retry-all-errors", "--retry-delay", "10", "--connect-timeout", "30",
                          "-C", "-", "-o", out.path, url.absoluteString]
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        return task.terminationStatus == 0 && fileExists(out.path) ? out : nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the file is deleted when this returns: keep it
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-\(UUID().uuidString)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                let url = downloadTask.originalRequest?.url?.absoluteString ?? "?"
                if http.statusCode >= 500 || http.statusCode == 429 {
                    throw RetryableDownloadError(description: "the server answered \(http.statusCode)")
                }
                throw InstallError.tool("The server answered \(http.statusCode) for \(url).")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

/// Tarballs already downloaded (or put there by hand): used when their SHA-256 matches, so a reinstall needs no network.
let downloadCache: URL = {
    let dir = supportDirectory.appendingPathComponent("Downloads")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

enum Installer {
    /// Downloads, checks and unpacks a component in place. `confirm` is asked with the licence file before anything
    /// is installed when the component has one; `progress` gets a fraction and a line of text.
    static func install(_ component: Component, confirm: (URL) async -> Bool,
                        progress: @escaping (Double?, String) -> Void) async throws {
        let archive: URL
        var temporary = false
        let fileName = URL(string: component.url)!.lastPathComponent
        let cached = downloadCache.appendingPathComponent(fileName)
        if fileExists(cached.path), (try? sha256(of: cached)) == component.sha256 {
            archive = cached
            progress(nil, "Using the copy of \(fileName) already on this Mac…")
        } else if let local = ProcessInfo.processInfo.environment["MH_COMPONENTS_DIR"] {
            archive = URL(fileURLWithPath: local).appendingPathComponent(fileName)
            progress(nil, "Using \(archive.lastPathComponent) from \(local)…")
        } else {
            progress(0, "Downloading \(component.name) \(component.version)…")
            let fetched = try await Download.fetchWithRetries(URL(string: component.url)!, progress: {
                progress($0, "Downloading \(component.name) \(component.version)…")
            }, note: { progress(nil, $0) })
            // kept in the cache for a reinstall; removed below if the checksum is wrong
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: fetched, to: cached)
            archive = cached
            temporary = true
        }
        progress(nil, "Checking \(component.name)…")
        guard try sha256(of: archive) == component.sha256 else {
            if temporary { try? FileManager.default.removeItem(at: archive) }
            throw InstallError.badChecksum(component.name)
        }

        progress(nil, "Unpacking \(component.name)…")
        let staging = supportDirectory.appendingPathComponent(".staging-\(component.id)")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])
        let unpacked = staging.appendingPathComponent(component.root)
        guard fileExists(unpacked.path) else { throw InstallError.badArchive(component.name) }

        if let license = component.license {
            guard await confirm(unpacked.appendingPathComponent(license)) else { throw InstallError.declined }
            settingsStore().set(component.version, forKey: SettingKey.appleLicenseAccepted)
        }
        if let team = component.signedBy, !NativeEngine.loaderSignatureValid(at: unpacked.path) {
            throw InstallError.tool("\(component.name): its signature is not the Developer ID team \(team)'s; it was not installed.")
        }
        let destination = URL(fileURLWithPath: component.destination)
        try? FileManager.default.removeItem(at: destination)   // a downloaded component, not the player's data
        try FileManager.default.moveItem(at: unpacked, to: destination)
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        try component.writeMarker()
        if component.id == "engine-native" || component.id == "wineloader", NativeEngine.filesPresent, NativeEngine.loaderPresent {
            try NativeEngine.linkLoader()
        }
        progress(1, "\(component.name) \(component.version) installed.")
    }

    /// Assembles the DirectX 12 shim from the engine's shim and Apple's d3d12 (see shimDirectory).
    static func prepareShim(engine: String, d3dmetal: String) throws {
        let fm = FileManager.default
        let windows = shimDirectory + "/x86_64-windows", unix = shimDirectory + "/x86_64-unix"
        try? fm.removeItem(atPath: shimDirectory)
        try fm.createDirectory(atPath: windows, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: unix, withIntermediateDirectories: true)
        try fm.copyItem(atPath: engine + "/renderers/tsshim/x86_64-windows/d3d12.dll", toPath: windows + "/d3d12.dll")
        try fm.copyItem(atPath: d3dmetal + "/wine/x86_64-windows/d3d12.dll", toPath: windows + "/apd12.dll")
        try PEFile.renameExport(at: windows + "/apd12.dll", to: "apd12.dll")
        // a link, not a copy: Apple's .so files are all one library, and a copy would be a second image
        try fm.createSymbolicLink(atPath: unix + "/apd12.so", withDestinationPath: d3dmetal + "/wine/x86_64-unix/d3d12.so")
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice
        try task.run()
        let err = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw InstallError.tool("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(String(decoding: err, as: UTF8.self))")
        }
    }
}
