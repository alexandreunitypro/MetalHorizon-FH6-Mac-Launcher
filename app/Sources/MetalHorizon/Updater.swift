import AppKit
import Foundation
import SwiftUI

// MetalHorizon updates itself. Each time the app opens (never the MCP server, a snapshot, or a development build that
// is not MetalHorizon.app), it reads the GitHub releases of the project, prereleases included. A newer version is
// mandatory: once nothing runs (game, download, install, Steam), a sheet without Cancel downloads
// MetalHorizon-<version>.zip, checks it against the release's SHA256SUMS, unzips it and checks the app inside (bundle
// identifier, version, executable, signature). A small helper script, started in a session of its own, then waits for
// the app to quit, puts the new MetalHorizon.app at the same path, relaunches it, and puts the previous one back if the
// new one does not start. Only the app is replaced: the settings (UserDefaults), the logs and the engines in
// Application Support stay as they are, and the new version installs the engines it needs by itself (components.json).
// Everything is written to ~/Library/Logs/MetalHorizon/updater.log; a failed check is silent.
// MH_UPDATE_FEED=<URL or file> reads another feed in the same format as GitHub's (tests).

/// A release version, "v0.4.1" or "0.4.1": compared number by number (0.10.0 is newer than 0.9.0), and a pre-release
/// such as 0.5.0-beta.1 comes before 0.5.0.
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let suffix: [String]        // after "-", split at the dots; empty for a release
    let description: String     // without the leading v

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }     // build metadata does not count
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        var numbers: [Int] = []
        for piece in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.count < 10, piece.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(piece) else { return nil }
            numbers.append(n)
        }
        if parts.count == 2 {
            guard !parts[1].isEmpty else { return nil }
            suffix = parts[1].split(separator: ".").map(String.init)
        } else {
            suffix = []
        }
        self.numbers = numbers
        description = s
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        if a.suffix.isEmpty != b.suffix.isEmpty { return !a.suffix.isEmpty }
        for (x, y) in zip(a.suffix, b.suffix) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true      // numbers come before words, as in semantic versioning
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.suffix.count < b.suffix.count
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A release as GitHub's API lists it; only what the updater reads.
struct FeedRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var url: String
        var size: Int64?
        enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", size }
    }
    var tag: String
    var draft: Bool
    var page: String?
    var assets: [Asset]

    enum CodingKeys: String, CodingKey { case tag = "tag_name", draft, page = "html_url", assets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        page = try c.decodeIfPresent(String.self, forKey: .page)
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

/// A newer version and the two files of its release.
struct AvailableUpdate: Equatable {
    var version: String
    var archive: URL
    var archiveSize: Int64?
    var checksums: URL
    var page: URL
    var archiveName: String { "MetalHorizon-\(version).zip" }
}

enum UpdateError: Error, CustomStringConvertible {
    case server(String), noChecksum(String), badChecksum(String), badApp(String), tool(String)
    var description: String {
        switch self {
        case .server(let m): return m
        case .noChecksum(let n): return "The release's SHA256SUMS has no line for \(n)."
        case .badChecksum(let n): return "\(n) does not match its SHA-256 in the release's SHA256SUMS: it was not installed."
        case .badApp(let m): return "The downloaded app was refused: \(m)."
        case .tool(let m): return m
        }
    }
}

// MARK: - The feed

enum UpdateFeed {
    static let releasesPage = URL(string: "https://github.com/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher/releases")!
    static let defaultURL = URL(string: "https://api.github.com/repos/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher/releases?per_page=20")!

    static var url: URL {
        guard let custom = ProcessInfo.processInfo.environment["MH_UPDATE_FEED"], !custom.isEmpty else { return defaultURL }
        return location(custom)
    }

    /// A URL as written, or a file path (the test feeds point at local files).
    static func location(_ text: String) -> URL {
        if text.contains("://"), let url = URL(string: text) { return url }
        return URL(fileURLWithPath: expandTilde(text))
    }

    /// The releases, newest first as GitHub lists them. A short timeout: the check must never hold the app up.
    static func releases(from feed: URL) async throws -> [FeedRelease] {
        let data: Data
        if feed.isFileURL {
            data = try Data(contentsOf: feed)
        } else {
            var request = URLRequest(url: feed, timeoutInterval: 8)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MetalHorizon/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (body, response) = try await UpdatePackage.session(timeout: 8).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let http = response as? HTTPURLResponse
                let remaining = http?.value(forHTTPHeaderField: "x-ratelimit-remaining").map { ", rate limit remaining \($0)" } ?? ""
                throw UpdateError.server("GitHub answered \(http?.statusCode ?? 0) for the releases\(remaining)")
            }
            data = body
        }
        return try JSONDecoder().decode([FeedRelease].self, from: data)
    }

    /// The highest version above `current` whose release is published (not a draft) and carries both
    /// MetalHorizon-<version>.zip and SHA256SUMS. Tags that are not versions are skipped.
    static func newest(in releases: [FeedRelease], above current: String) -> AvailableUpdate? {
        guard let running = AppVersion(current) else { return nil }
        var best: (version: AppVersion, update: AvailableUpdate)?
        for release in releases where !release.draft {
            guard let version = AppVersion(release.tag), version > running else { continue }
            if let best, best.version >= version { continue }
            guard let zip = release.assets.first(where: { $0.name == "MetalHorizon-\(version).zip" }),
                  let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else { continue }
            let page = release.page.flatMap(URL.init(string:)) ?? releasesPage.appendingPathComponent("tag/\(release.tag)")
            best = (version, AvailableUpdate(version: version.description, archive: location(zip.url), archiveSize: zip.size,
                                             checksums: location(sums.url), page: page))
        }
        return best?.update
    }
}

// MARK: - Download and checks

/// Downloads with progress into a given file (URLSession's async download gives none).
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let progress: (Int64, Int64) -> Void

    private init(destination: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ source: URL, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        if source.isFileURL {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let download = UpdateDownload(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30          // no data for 30 s: stop
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            download.continuation = continuation
            session.downloadTask(with: source).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the file is deleted when this returns: move it now
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.server("The server answered \(http.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "the update").")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

enum UpdatePackage {
    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: configuration)
    }

    /// SHA256SUMS as shasum writes it: "<sha256>  <file>" (or "<sha256> *<file>" in binary mode), one file per line.
    static func parseChecksums(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let gap = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = trimmed[..<gap].lowercased()
            var name = trimmed[gap...].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit), !name.isEmpty else { continue }
            sums[name] = hash
        }
        return sums
    }

    static func verifyChecksum(of file: URL, named name: String, in sums: [String: String]) throws {
        guard let expected = sums[name] else { throw UpdateError.noChecksum(name) }
        guard try Installer.sha256(of: file) == expected else { throw UpdateError.badChecksum(name) }
    }

    /// The unzipped archive must hold exactly one MetalHorizon.app, with this app's bundle identifier, the release's
    /// version, its executable, and a signature that verifies (ad-hoc signatures do).
    static func verifyApp(in folder: URL, bundleID: String, version: String) throws -> URL {
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard items == ["MetalHorizon.app"] else {
            throw UpdateError.badApp("the archive should hold only MetalHorizon.app, it holds \(items.isEmpty ? "nothing" : items.sorted().joined(separator: ", "))")
        }
        let app = folder.appendingPathComponent("MetalHorizon.app")
        guard let data = FileManager.default.contents(atPath: app.path + "/Contents/Info.plist"),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.badApp("it has no readable Info.plist")
        }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleID else { throw UpdateError.badApp("its bundle identifier is \(id.isEmpty ? "missing" : id), not \(bundleID)") }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard found == version else { throw UpdateError.badApp("it is version \(found.isEmpty ? "?" : found), not \(version)") }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: app.path + "/Contents/MacOS/" + executable) else {
            throw UpdateError.badApp("its executable is missing")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.badApp("its signature does not verify (\(error))")
        }
        return app
    }

    /// Downloads the update into `work` (a folder on the app's volume), checks it and returns the new MetalHorizon.app
    /// inside `work`. Nothing outside `work` is touched.
    static func prepare(_ update: AvailableUpdate, in work: URL, bundleID: String,
                        progress: @escaping @Sendable (Double?, String) -> Void) async throws -> URL {
        progress(nil, "Reading the release's checksums…")
        let sumsData: Data
        if update.checksums.isFileURL {
            sumsData = try Data(contentsOf: update.checksums)
        } else {
            let (body, response) = try await session(timeout: 20).data(from: update.checksums)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.server("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for SHA256SUMS.")
            }
            sumsData = body
        }
        let sums = parseChecksums(String(decoding: sumsData, as: UTF8.self))
        let name = update.archiveName
        guard sums[name] != nil else { throw UpdateError.noChecksum(name) }

        let downloading = "Downloading MetalHorizon \(update.version)…"
        progress(0, downloading)
        let archive = work.appendingPathComponent(name)
        try await UpdateDownload.fetch(update.archive, to: archive) { written, total in
            let total = total > 0 ? total : (update.archiveSize ?? 0)
            guard total > 0 else { progress(nil, downloading); return }
            let mb = { (bytes: Int64) in String(format: "%.0f", Double(bytes) / 1_000_000) }
            progress(min(1, Double(written) / Double(total)), "\(downloading) \(mb(written)) of \(mb(total)) MB")
        }
        progress(nil, "Checking the download's SHA-256…")
        try verifyChecksum(of: archive, named: name, in: sums)
        progress(nil, "Unpacking…")
        let unpacked = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        progress(nil, "Checking the new app's signature…")
        return try verifyApp(in: unpacked, bundleID: bundleID, version: update.version)
    }

    static func run(_ path: String, _ args: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = pipe
        try task.run()
        let err = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let text = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.tool("\(URL(fileURLWithPath: path).lastPathComponent) failed\(text.isEmpty ? "" : ": " + text)")
        }
    }
}

// MARK: - The helper that swaps the app

enum UpdateHelper {
    /// Written by each launch with its version: the helper's sign that the new version really started.
    static var readyFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-update-ready") }
    /// Written by the helper when it had to put the previous version back, read by that version's next launch.
    static var failedFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-update-failed") }
    /// Marks a work folder as the updater's own: the only folder the helper ever deletes.
    static let workMarker = ".metalhorizon-update"

    /// Why this copy cannot replace itself, or nil when it can.
    static func swapProblem(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "macOS runs this copy from a temporary read-only place (App Translocation), so it cannot replace itself. Quit MetalHorizon, move it to the Applications folder in Finder and open it again: from there it updates by itself."
        }
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent().path
        if !fm.isWritableFile(atPath: folder) || !fm.isWritableFile(atPath: app.path) {
            return "This copy is in \(folder), where your account cannot write, so it cannot replace itself. Download the new version from the release page and replace the app with it, or move MetalHorizon to a folder you can write to."
        }
        return nil
    }

    /// The helper's environment: what it reads (MH_UPDATE_*), plus the few variables an app opened from Finder has,
    /// because `open` passes the helper's environment on to the relaunched app. MetalHorizon's test switches and
    /// DYLD_ variables are left out.
    static func environment(app: URL, newApp: URL, work: URL, version: String, oldVersion: String,
                            executable: String) -> [String: String] {
        let keep = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK"]
        var env = ProcessInfo.processInfo.environment.filter { keep.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge([
            "MH_UPDATE_APP": app.path,
            "MH_UPDATE_NEW": newApp.path,
            "MH_UPDATE_WORK": work.path,
            "MH_UPDATE_PID": String(getpid()),
            "MH_UPDATE_VERSION": version,
            "MH_UPDATE_OLD_VERSION": oldVersion,
            "MH_UPDATE_EXECUTABLE": executable,
            "MH_UPDATE_READY": readyFile.path,
            "MH_UPDATE_FAILED": failedFile.path,
            "MH_UPDATE_LOG": Updater.logFile.path
        ]) { _, new in new }
        return env
    }

    /// Starts the helper in a session of its own, so the app's exit does not take it along, with no descriptor of the
    /// app and its output in updater.log. Not nohup: /usr/bin/nohup is SIP-protected (see metalhorizon-steam.sh). Not a
    /// launchd job either: tried on this Mac, a job's bash may not read the work folder macOS gave the app
    /// (TemporaryItems, "Operation not permitted"); a child of the app may, and it ignores the TERM it gets once the app
    /// has quit (see the script).
    @discardableResult
    static func launch(_ script: URL, environment: [String: String], log: URL) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var pid: pid_t = 0
        let rc = withCStrings(["/bin/bash", script.path]) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, "/bin/bash", &actions, &attributes, argv, envp)
            }
        }
        guard rc == 0 else { throw UpdateError.tool("Could not start the update helper: \(String(cString: strerror(rc))).") }
        return pid
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }

    /// The helper. It reads MH_UPDATE_* (see environment(...)); MH_UPDATE_RELAUNCH (default /usr/bin/open),
    /// MH_UPDATE_TIMEOUT (seconds the new version has to start, default 20), MH_UPDATE_QUIT_TIMEOUT (seconds the app has
    /// to quit, default 60) and MH_UPDATE_TRASH (default ~/.Trash) let the tests run it on fake apps.
    static let script = #"""
    #!/bin/bash
    # MetalHorizon's update helper, written by Updater.swift and started detached from the app. Once the app has quit, it
    # puts the verified new MetalHorizon.app at the same path, relaunches it, and puts the previous one back if the new
    # one does not start. It deletes nothing but its own work folder; the previous app goes to the Trash.
    set -u
    # A swap must not stop halfway. About a second after the app quits, macOS sends TERM to what it started, this
    # helper's process group included (seen on this Mac, macOS 27.2: without this line the helper died with the previous
    # app still in the work folder; with it, no KILL followed in 75 s). Ignored, not handled, so that mv, open and
    # sleep ignore it too.
    trap '' HUP TERM
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    APP="$MH_UPDATE_APP"; NEW="$MH_UPDATE_NEW"; WORK="$MH_UPDATE_WORK"
    PID="${MH_UPDATE_PID:-0}"; VERSION="$MH_UPDATE_VERSION"; OLD_VERSION="${MH_UPDATE_OLD_VERSION:-previous}"
    EXECUTABLE="${MH_UPDATE_EXECUTABLE:-MetalHorizon}"
    READY="$MH_UPDATE_READY"; FAILED="$MH_UPDATE_FAILED"; LOG="${MH_UPDATE_LOG:-/dev/stderr}"
    RELAUNCH="${MH_UPDATE_RELAUNCH:-/usr/bin/open}"
    START_WAIT="${MH_UPDATE_TIMEOUT:-20}"; QUIT_WAIT="${MH_UPDATE_QUIT_TIMEOUT:-60}"
    TRASH="${MH_UPDATE_TRASH:-$HOME/.Trash}"
    BACKUP="$WORK/previous/$(basename "$APP")"
    # `open` passes this environment on to the app it opens: the app does not need these
    unset MH_UPDATE_APP MH_UPDATE_NEW MH_UPDATE_WORK MH_UPDATE_PID MH_UPDATE_VERSION MH_UPDATE_OLD_VERSION \
          MH_UPDATE_EXECUTABLE MH_UPDATE_READY MH_UPDATE_FAILED MH_UPDATE_LOG MH_UPDATE_RELAUNCH MH_UPDATE_TIMEOUT \
          MH_UPDATE_QUIT_TIMEOUT MH_UPDATE_TRASH

    log() { printf '%s helper: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

    # The work folder is deleted only when the app marked it as its own, and never with the previous app still in it
    # unless that app is back in place.
    clean_work() {
        [ -n "$WORK" ] && [ -d "$WORK" ] && [ -f "$WORK/.metalhorizon-update" ] || return 0
        if [ "${1:-}" = keep-previous ]; then
            find "$WORK" -mindepth 1 -maxdepth 1 ! -name previous -exec rm -rf {} +
        else
            rm -rf "$WORK"
        fi
    }

    relaunch() { "$RELAUNCH" "$1" >> "$LOG" 2>&1; }

    # The installed app is the previous one (it never moved, or it is back): note the version, so that the app does not
    # try it again by itself, and reopen it.
    give_up() {
        log "$1"
        printf '%s\n' "$VERSION" > "$FAILED"
        relaunch "$APP" || log "could not reopen $APP"
        clean_work
        exit 1
    }

    # The previous app cannot be put back: say where it is, keep it, and still try to leave an app at $APP.
    stranded() {
        log "$1. THE PREVIOUS APP IS KEPT AT $BACKUP: move it back to $APP by hand if needed."
        printf '%s\n' "$VERSION" > "$FAILED"
        [ -e "$APP" ] && relaunch "$APP"
        exit 2
    }

    # The new version runs: a process started from its executable (not an MCP server started with --mcp).
    new_app_running() {
        local exe="$APP/Contents/MacOS/$EXECUTABLE" line
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            case "$line" in
                *" --mcp"*) ;;
                "$exe"|"$exe "*) return 0 ;;
            esac
        done < <(ps -axww -o args=)
        return 1
    }

    log "installing MetalHorizon $VERSION at $APP once MetalHorizon $OLD_VERSION (pid $PID) has quit"
    waited=0
    while [ "$PID" -gt 0 ] && kill -0 "$PID" 2>/dev/null; do
        if [ "$waited" -ge $((QUIT_WAIT * 10)) ]; then
            log "MetalHorizon did not quit within ${QUIT_WAIT} s: nothing was changed"
            clean_work
            exit 1
        fi
        sleep 0.1; waited=$((waited + 1))
    done

    # The swap: two renames on the same volume (the work folder is next to the app's).
    mkdir -p "$WORK/previous" || give_up "could not create $WORK/previous: nothing was changed"
    mv "$APP" "$BACKUP" || give_up "could not move $APP aside: nothing was changed"
    if ! mv "$NEW" "$APP"; then
        log "could not move MetalHorizon $VERSION to $APP: putting $OLD_VERSION back"
        if [ -e "$APP" ]; then mv "$APP" "$WORK/incomplete.app" || stranded "could not clear $APP"; fi
        mv "$BACKUP" "$APP" || stranded "could not put MetalHorizon $OLD_VERSION back"
        give_up "MetalHorizon $OLD_VERSION is back at $APP"
    fi

    # Relaunch and wait for the new version to say it started (it writes its version to $READY); after the wait, a
    # process running from it counts too.
    rm -f "$READY"
    log "MetalHorizon $VERSION is at $APP: opening it"
    started=no
    if relaunch "$APP"; then
        tries=0
        while [ "$tries" -lt $((START_WAIT * 10)) ]; do
            if [ -f "$READY" ] && [ "$(head -n 1 "$READY" 2>/dev/null)" = "$VERSION" ]; then started=yes; break; fi
            sleep 0.1; tries=$((tries + 1))
        done
        if [ "$started" = no ] && new_app_running; then started=yes; fi
    else
        log "$RELAUNCH could not open $APP"
    fi

    if [ "$started" = yes ]; then
        dest="$TRASH/MetalHorizon $OLD_VERSION.app"; n=2
        while [ -e "$dest" ]; do dest="$TRASH/MetalHorizon $OLD_VERSION ($n).app"; n=$((n + 1)); done
        if mkdir -p "$TRASH" && mv "$BACKUP" "$dest"; then
            log "MetalHorizon $VERSION started; MetalHorizon $OLD_VERSION is in the Trash"
            clean_work
        else
            log "MetalHorizon $VERSION started; MetalHorizon $OLD_VERSION could not go to the Trash and stays at $BACKUP"
            clean_work keep-previous
        fi
        exit 0
    fi

    # Rollback: the new version is set aside in the work folder and the previous one goes back to its place.
    log "MetalHorizon $VERSION did not start within ${START_WAIT} s: putting MetalHorizon $OLD_VERSION back"
    mv "$APP" "$WORK/failed-$VERSION.app" || stranded "could not move MetalHorizon $VERSION away from $APP"
    if ! mv "$BACKUP" "$APP"; then
        mv "$WORK/failed-$VERSION.app" "$APP"
        stranded "could not put MetalHorizon $OLD_VERSION back"
    fi
    give_up "MetalHorizon $OLD_VERSION is back at $APP"
    """#
}

// MARK: - The app's side

private enum UpdateKey {
    static let lastRunVersion = "metalhorizon.lastRunVersion"
    static let failedVersion = "metalhorizon.updateFailedVersion"     // a version the helper had to put back
}

/// What the update sheet shows.
enum UpdateState: Equatable {
    case none
    /// The mandatory update: progress, no Cancel.
    case updating(version: String, step: String, fraction: Double?)
    /// Something to read, with the release page when there is one and Try Again when it can be retried.
    case notice(title: String, text: String, page: URL?, retry: Bool)
}

@MainActor
final class Updater: ObservableObject {
    @Published private(set) var state = UpdateState.none
    private var started = false
    private var checking = false
    private weak var model: LauncherModel?

    nonisolated static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    nonisolated static let logFile = logDirectory.appendingPathComponent("updater.log")

    /// Whether this copy updates itself: MetalHorizon.app with its bundle identifier (not a development build run from
    /// .build), and neither the MCP server nor a snapshot.
    static var enabled: Bool {
        !CommandLine.arguments.contains("--mcp") && ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil
            && Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    var isForced: Bool { if case .updating = state { return true } else { return false } }

    /// Once per launch, when the window appears: notes this version, then looks for a newer one.
    func start(model: LauncherModel) {
        if ProcessInfo.processInfo.environment["MH_SNAPSHOT_SHEET"] == "update" {     // the sheet's layout check
            state = .updating(version: "0.4.1", step: "Downloading MetalHorizon 0.4.1… 21 of 48 MB", fraction: 0.44)
            return
        }
        guard !started else { return }
        started = true
        self.model = model
        guard Self.enabled else { return }
        noteLaunch(model)
        Task { await check(userInitiated: false) }
    }

    /// MetalHorizon › Check for Updates…: the same check, and it says what it found.
    func checkNow(model: LauncherModel) {
        self.model = model
        guard Self.enabled else {
            Task {
                await show(.notice(title: "Updates", text: "This is a development build: only MetalHorizon.app updates itself.",
                                   page: UpdateFeed.releasesPage, retry: false))
            }
            return
        }
        Task { await check(userInitiated: true) }
    }

    func retry() {
        settingsStore().removeObject(forKey: UpdateKey.failedVersion)
        state = .none
        Task { await check(userInitiated: true) }
    }

    func dismiss() {
        guard !isForced else { return }
        state = .none
    }

    // MARK: Steps

    private func noteLaunch(_ model: LauncherModel) {
        let current = Self.currentVersion
        // first, the sign the helper of an update waits for
        try? (current + "\n").write(to: UpdateHelper.readyFile, atomically: true, encoding: .utf8)
        let defaults = settingsStore()
        if let previous = defaults.string(forKey: UpdateKey.lastRunVersion), previous != current,
           let old = AppVersion(previous), let new = AppVersion(current), new > old {
            model.status = "Updated to \(current)."
            Self.log("MetalHorizon \(current) started (it was \(previous))")
        }
        defaults.set(current, forKey: UpdateKey.lastRunVersion)
        if let text = try? String(contentsOf: UpdateHelper.failedFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: UpdateHelper.failedFile)
            let failed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !failed.isEmpty, failed != current {
                defaults.set(failed, forKey: UpdateKey.failedVersion)
                model.status = "The update to \(failed) did not complete; MetalHorizon \(current) was kept (see updater.log)."
            }
        }
    }

    private func check(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let current = Self.currentVersion
        let update: AvailableUpdate?
        do {
            let releases = try await UpdateFeed.releases(from: UpdateFeed.url)
            update = UpdateFeed.newest(in: releases, above: current)
        } catch {
            // offline, rate limit, GitHub down: the app works as before, the next launch checks again
            Self.log("could not check for updates: \(error)")
            if userInitiated {
                await show(.notice(title: "Could not check for updates", text: "\(error)", page: UpdateFeed.releasesPage, retry: true))
            }
            return
        }
        guard let update else {
            Self.log("MetalHorizon \(current) is the newest version")
            if userInitiated {
                await show(.notice(title: "MetalHorizon is up to date", text: "Version \(current) is the newest.", page: nil, retry: false))
            }
            return
        }
        Self.log("MetalHorizon \(update.version) is available (this is \(current))")
        await install(update, userInitiated: userInitiated)
    }

    private func install(_ update: AvailableUpdate, userInitiated: Bool) async {
        let current = Self.currentVersion
        let app = Bundle.main.bundleURL
        let keep = "Your settings, sign-in, engines and game stay as they are."
        if !userInitiated, settingsStore().string(forKey: UpdateKey.failedVersion) == update.version {
            // the helper put this copy back after that version did not start: no loop, the user decides
            Self.log("MetalHorizon \(update.version) did not start after the last update: not installing it again by itself")
            await show(.notice(title: "MetalHorizon \(update.version) is available",
                               text: "The last automatic update to \(update.version) did not start, so MetalHorizon \(current) was put back (details in updater.log). Try again, or download it from the release page and replace the app. \(keep)",
                               page: update.page, retry: true))
            return
        }
        if let problem = UpdateHelper.swapProblem(app) {
            Self.log("cannot update in place: \(problem)")
            await show(.notice(title: "MetalHorizon \(update.version) is available", text: "\(problem) \(keep)",
                               page: update.page, retry: false))
            return
        }

        await show(.updating(version: update.version, step: "Starting the download…", fraction: nil))
        let fm = FileManager.default
        var work: URL?
        do {
            // a folder on the app's own volume, so that the helper's swap is two renames
            let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            work = folder
            fm.createFile(atPath: folder.appendingPathComponent(UpdateHelper.workMarker).path, contents: nil)
            Self.log("downloading \(update.archive.absoluteString) into \(folder.path)")
            let newApp = try await UpdatePackage.prepare(update, in: folder, bundleID: Bundle.main.bundleIdentifier ?? appBundleID) { [weak self] fraction, step in
                Task { @MainActor in self?.progress(update.version, step, fraction) }
            }
            Self.log("MetalHorizon \(update.version) downloaded and verified (SHA-256, bundle, signature)")

            // a menu command may have started something meanwhile: the swap waits for it to end
            if model?.isBusy == true {
                progress(update.version, "Waiting for what runs to finish…", nil)
                while model?.isBusy == true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            progress(update.version, "Restarting MetalHorizon…", nil)
            let script = folder.appendingPathComponent("update-helper.sh")
            try UpdateHelper.script.write(to: script, atomically: true, encoding: .utf8)
            let executable = Bundle.main.executableURL?.lastPathComponent ?? "MetalHorizon"
            let env = UpdateHelper.environment(app: app, newApp: newApp, work: folder, version: update.version,
                                               oldVersion: current, executable: executable)
            let pid = try UpdateHelper.launch(script, environment: env, log: Self.logFile)
            Self.log("helper \(pid) started; quitting so that it can replace \(app.path)")
            quitForUpdate()
        } catch {
            if let work { try? fm.removeItem(at: work) }
            Self.log("update to \(update.version) failed: \(error)")
            state = .notice(title: "MetalHorizon could not update to \(update.version)",
                            text: "\(error)\n\nNothing was changed: MetalHorizon \(current) keeps working, and it tries again the next time it opens.",
                            page: update.page, retry: true)
        }
    }

    /// AppKit does not quit while a window has a sheet attached, the update sheet included (seen on this Mac: the app
    /// stayed open and the helper gave up after a minute). The sheets are ended first, in the same turn as the quit, so
    /// the window cannot be used in between; if the app is still here after 3 s, it leaves anyway: nothing runs, and
    /// the helper is waiting for this exit.
    private func quitForUpdate() {
        state = .none
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        settingsStore().synchronize()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Self.log("MetalHorizon did not quit by itself; leaving so that the update can go on")
            exit(0)
        }
    }

    private func progress(_ version: String, _ step: String, _ fraction: Double?) {
        guard isForced else { return }      // a late progress report must not cover the error that followed it
        state = .updating(version: version, step: step, fraction: fraction)
    }

    /// Presents the sheet once the window is free: nothing runs (game, download, install, Steam, sign-in) and no other
    /// sheet or modal panel is open, so the update never cuts into anything and never hides a Stop button.
    private func show(_ newState: UpdateState) async {
        if state == .none {
            while !windowIsFree { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        state = newState
    }

    private var windowIsFree: Bool {
        if let model, model.isBusy || model.showWelcome || model.licenseText != nil { return false }
        return NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
    }

    // MARK: Log

    /// One line in ~/Library/Logs/MetalHorizon/updater.log (the helper writes to the same file); kept under 1 MB.
    nonisolated static func log(_ message: String) {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber, size.intValue > 1 << 20 {
            let old = logDirectory.appendingPathComponent("updater.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logFile, to: old)
        }
        let line = "\(stamp.string(from: Date())) app \(currentVersion.isEmpty ? "dev" : currentVersion): \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logFile, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - Window

extension View {
    /// The update check at start-up and its sheet (the hook in MetalHorizonApp).
    func appUpdates(_ updater: Updater, model: LauncherModel) -> some View {
        modifier(UpdateHook(updater: updater, model: model))
    }
}

private struct UpdateHook: ViewModifier {
    @ObservedObject var updater: Updater
    let model: LauncherModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { updater.state != .none }, set: { if !$0 { updater.dismiss() } })) {
                UpdateSheet(updater: updater)
            }
            .onAppear { updater.start(model: model) }
    }
}

struct UpdateSheet: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.state {
            case .none:
                EmptyView()
            case let .updating(version, step, fraction):
                Text("Updating MetalHorizon to \(version)…")
                    .font(.headline)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(step)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("This update is required. MetalHorizon restarts by itself when it is done; your settings, sign-in, engines and game stay as they are.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .notice(title, text, page, retry):
                Text(title)
                    .font(.headline)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    if let page {
                        Button("Open the Release Page") { NSWorkspace.shared.open(page) }
                    }
                    Spacer()
                    if retry {
                        Button("Try Again") { updater.retry() }
                    }
                    Button(page == nil && !retry ? "OK" : "Continue") { updater.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(updater.isForced)
    }
}
