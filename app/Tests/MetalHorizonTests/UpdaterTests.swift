import XCTest
@testable import MetalHorizon

// The self-update without the network and without a real relaunch: versions, picking the release from a feed,
// SHA256SUMS, the downloaded app's checks (on ad-hoc signed fake apps, through file:// URLs), and the helper script's
// swap, Trash and rollback on fake .app folders, with the relaunch command replaced by a script that records its calls.
final class UpdaterTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mh-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // a test may have made a folder read-only
        if let items = FileManager.default.enumerator(atPath: root.path) {
            for case let item as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(item).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// A fake MetalHorizon.app: its Info.plist and an executable (/usr/bin/true when it is to be signed).
    @discardableResult
    private func fakeApp(_ url: URL, version: String, bundleID: String = appBundleID, signed: Bool = false) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                   "CFBundleExecutable": "MetalHorizon", "CFBundlePackageType": "APPL", "CFBundleName": "MetalHorizon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try "settings stay".write(to: url.appendingPathComponent("Contents/Resources/components.json"), atomically: true, encoding: .utf8)
        let exe = url.appendingPathComponent("Contents/MacOS/MetalHorizon")
        if signed {
            try fm.copyItem(atPath: "/usr/bin/true", toPath: exe.path)
            try shell("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        } else {
            try "#!/bin/bash\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
        return url
    }

    private func version(of app: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: app.path + "/Contents/Info.plist") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    @discardableResult
    private func shell(_ path: String, _ args: [String], env: [String: String]? = nil) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if let env { task.environment = env }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        if env == nil, task.terminationStatus != 0 { XCTFail("\(path) \(args): \(out)") }
        return (task.terminationStatus, out)
    }

    // MARK: Versions and feed

    func testVersionsCompareNumberByNumber() throws {
        let v = { (s: String) in try XCTUnwrap(AppVersion(s)) }
        XCTAssertLessThan(try v("0.4.0"), try v("0.4.1"))
        XCTAssertLessThan(try v("0.4.1"), try v("0.10.0"))
        XCTAssertLessThan(try v("0.9.9"), try v("0.10.0"))
        XCTAssertLessThan(try v("0.4.9"), try v("1.0.0"))
        XCTAssertEqual(try v("v0.4.0"), try v("0.4.0"))
        XCTAssertEqual(try v("V0.4.0").description, "0.4.0")
        XCTAssertEqual(try v("0.4"), try v("0.4.0"))
        XCTAssertLessThan(try v("0.5.0-beta.1"), try v("0.5.0"))
        XCTAssertLessThan(try v("0.5.0-beta.1"), try v("0.5.0-beta.2"))
        XCTAssertLessThan(try v("0.5.0-beta.2"), try v("0.5.0-beta.10"))
        XCTAssertLessThan(try v("0.4.9"), try v("0.5.0-beta.1"))
        for bad in ["", "v", "dev", "blackwell-engine-1.1", "0..1", "1.a", "0.4.0-"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testNewestReleaseFromAFeed() throws {
        func asset(_ name: String) -> String {
            "{\"name\": \"\(name)\", \"browser_download_url\": \"https://github.com/o/r/releases/download/x/\(name)\", \"size\": 1000}"
        }
        let feed = """
        [
          {"tag_name": "v0.6.0", "draft": true, "prerelease": true, "assets": [\(asset("MetalHorizon-0.6.0.zip")), \(asset("SHA256SUMS"))]},
          {"tag_name": "v0.5.0", "draft": false, "prerelease": true, "assets": [\(asset("SHA256SUMS")), \(asset("xodus-source-0.5.0.tar.gz"))]},
          {"tag_name": "v0.4.3", "draft": false, "prerelease": true, "assets": [\(asset("MetalHorizon-0.4.3.zip"))]},
          {"tag_name": "v0.4.2", "draft": false, "prerelease": true, "html_url": "https://github.com/o/r/releases/tag/v0.4.2",
           "assets": [\(asset("MetalHorizon-0.4.2.zip")), \(asset("xodus-source-0.4.2.tar.gz")), \(asset("SHA256SUMS"))]},
          {"tag_name": "v0.4.1", "prerelease": true, "assets": [\(asset("MetalHorizon-0.4.1.zip")), \(asset("SHA256SUMS"))]},
          {"tag_name": "blackwell-engine-1.1", "assets": [\(asset("MetalHorizon-9.9.9.zip")), \(asset("SHA256SUMS"))]},
          {"tag_name": "v0.3.1", "assets": [\(asset("MetalHorizon-0.3.1.zip")), \(asset("SHA256SUMS"))]}
        ]
        """
        let file = root.appendingPathComponent("releases.json")
        try feed.write(to: file, atomically: true, encoding: .utf8)
        let releases = try JSONDecoder().decode([FeedRelease].self, from: Data(feed.utf8))
        XCTAssertEqual(releases.count, 7)

        // the draft, the release without its zip and the one without SHA256SUMS are skipped
        let update = try XCTUnwrap(UpdateFeed.newest(in: releases, above: "0.4.0"))
        XCTAssertEqual(update.version, "0.4.2")
        XCTAssertEqual(update.archiveName, "MetalHorizon-0.4.2.zip")
        XCTAssertEqual(update.archive.absoluteString, "https://github.com/o/r/releases/download/x/MetalHorizon-0.4.2.zip")
        XCTAssertEqual(update.checksums.lastPathComponent, "SHA256SUMS")
        XCTAssertEqual(update.page.absoluteString, "https://github.com/o/r/releases/tag/v0.4.2")
        XCTAssertEqual(update.archiveSize, 1000)
        XCTAssertEqual(UpdateFeed.newest(in: releases, above: "0.4.1")?.version, "0.4.2")
        XCTAssertNil(UpdateFeed.newest(in: releases, above: "0.4.2"))
        XCTAssertNil(UpdateFeed.newest(in: releases, above: "0.10.0"))
        XCTAssertNil(UpdateFeed.newest(in: releases, above: ""), "a copy without a version never updates")
        XCTAssertEqual(UpdateFeed.newest(in: releases, above: "0.3.1")?.version, "0.4.2")

        // MH_UPDATE_FEED takes a path or a URL
        XCTAssertTrue(UpdateFeed.location(file.path).isFileURL)
        XCTAssertFalse(UpdateFeed.location("https://api.github.com/x").isFileURL)
        let loaded = try awaitResult { try await UpdateFeed.releases(from: UpdateFeed.location(file.path)) }
        XCTAssertEqual(loaded.map(\.tag).first, "v0.6.0")
        XCTAssertThrowsError(try awaitResult { try await UpdateFeed.releases(from: self.root.appendingPathComponent("none.json")) })
    }

    func testChecksumsParse() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let sums = UpdatePackage.parseChecksums("""
            \(a)  MetalHorizon-0.4.1.zip
            \(b) *xodus-source-0.4.1.tar.gz

            not a checksum line
            1234  short.zip
            """)
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(sums["MetalHorizon-0.4.1.zip"], a)
        XCTAssertEqual(sums["xodus-source-0.4.1.tar.gz"], b.lowercased())
    }

    func testMismatchedChecksumIsRefused() throws {
        let file = root.appendingPathComponent("MetalHorizon-0.4.1.zip")
        try Data("the download".utf8).write(to: file)
        let real = try Installer.sha256(of: file)
        XCTAssertNoThrow(try UpdatePackage.verifyChecksum(of: file, named: file.lastPathComponent, in: [file.lastPathComponent: real]))
        let wrong = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try UpdatePackage.verifyChecksum(of: file, named: file.lastPathComponent, in: [file.lastPathComponent: wrong])) {
            guard case UpdateError.badChecksum = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UpdatePackage.verifyChecksum(of: file, named: file.lastPathComponent, in: ["other.zip": real])) {
            guard case UpdateError.noChecksum = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: The downloaded app

    /// A release folder as build-app.sh makes it (the app zipped with ditto --keepParent, SHA256SUMS), as an update.
    private func release(label: String, appVersion: String? = nil, tamper: Bool = false, wrongSum: Bool = false,
                         bundleID: String = appBundleID) throws -> AvailableUpdate {
        let dir = root.appendingPathComponent("release-\(UUID().uuidString)")
        let app = try fakeApp(dir.appendingPathComponent("build/MetalHorizon.app"), version: appVersion ?? label,
                              bundleID: bundleID, signed: true)
        if tamper {    // changed after signing: the signature no longer verifies
            try "changed".write(to: app.appendingPathComponent("Contents/Resources/components.json"), atomically: true, encoding: .utf8)
        }
        let zip = dir.appendingPathComponent("MetalHorizon-\(label).zip")
        try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        let sum = wrongSum ? String(repeating: "0", count: 64) : try Installer.sha256(of: zip)
        let sums = dir.appendingPathComponent("SHA256SUMS")
        try "\(sum)  \(zip.lastPathComponent)\n\(String(repeating: "1", count: 64))  xodus-source-\(label).tar.gz\n"
            .write(to: sums, atomically: true, encoding: .utf8)
        return AvailableUpdate(version: label, archive: zip, archiveSize: nil, checksums: sums,
                               page: URL(string: "https://example.invalid/release")!)
    }

    private func prepare(_ update: AvailableUpdate) throws -> URL {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try awaitResult { try await UpdatePackage.prepare(update, in: work, bundleID: appBundleID) { _, _ in } }
    }

    func testDownloadedAppIsChecked() throws {
        // the good release: downloaded (file:// here), checksum, unzip, bundle, version, executable, signature
        let app = try prepare(try release(label: "0.4.1"))
        XCTAssertEqual(app.lastPathComponent, "MetalHorizon.app")
        XCTAssertEqual(app.deletingLastPathComponent().lastPathComponent, "unpacked")
        XCTAssertEqual(version(of: app), "0.4.1")

        func refused(_ update: AvailableUpdate, _ expected: String) {
            XCTAssertThrowsError(try prepare(update), expected) { XCTAssertTrue("\($0)".contains(expected), "\($0)") }
        }
        refused(try release(label: "0.4.1", wrongSum: true), "does not match its SHA-256")
        refused(try release(label: "0.4.1", appVersion: "0.4.0"), "it is version 0.4.0, not 0.4.1")
        refused(try release(label: "0.4.1", bundleID: "com.example.other"), "bundle identifier is com.example.other")
        refused(try release(label: "0.4.1", tamper: true), "signature does not verify")

        // two apps in the archive
        let folder = root.appendingPathComponent("two")
        try fakeApp(folder.appendingPathComponent("MetalHorizon.app"), version: "0.4.1", signed: true)
        try fakeApp(folder.appendingPathComponent("Other.app"), version: "0.4.1", signed: true)
        XCTAssertThrowsError(try UpdatePackage.verifyApp(in: folder, bundleID: appBundleID, version: "0.4.1")) {
            XCTAssertTrue("\($0)".contains("only MetalHorizon.app"), "\($0)")
        }
    }

    func testSwapNeedsAWritableFolderAndNoTranslocation() throws {
        let folder = root.appendingPathComponent("Applications")
        let app = try fakeApp(folder.appendingPathComponent("MetalHorizon.app"), version: "0.4.0")
        XCTAssertNil(UpdateHelper.swapProblem(app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertTrue(UpdateHelper.swapProblem(app)?.contains("cannot write") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/1234/d/MetalHorizon.app")
        XCTAssertTrue(UpdateHelper.swapProblem(translocated)?.contains("App Translocation") == true)
    }

    // MARK: The helper script

    private struct Layout {
        var app: URL, new: URL, work: URL, trash: URL, ready: URL, failed: URL, log: URL, relaunched: URL, other: URL
    }

    /// /Applications with the running 0.4.0 and another app, the work folder with the verified 0.4.1, a Trash.
    private func layout() throws -> Layout {
        let applications = root.appendingPathComponent("Applications")
        let work = root.appendingPathComponent("NSIRD_MetalHorizon")
        let l = Layout(app: applications.appendingPathComponent("MetalHorizon.app"),
                       new: work.appendingPathComponent("unpacked/MetalHorizon.app"),
                       work: work, trash: root.appendingPathComponent("Trash"),
                       ready: root.appendingPathComponent("ready"), failed: root.appendingPathComponent("failed"),
                       log: root.appendingPathComponent("updater.log"), relaunched: root.appendingPathComponent("relaunched"),
                       other: applications.appendingPathComponent("Other.app"))
        try fakeApp(l.app, version: "0.4.0")
        try fakeApp(l.new, version: "0.4.1")
        try FileManager.default.createDirectory(at: l.other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: l.trash, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: work.appendingPathComponent(UpdateHelper.workMarker).path, contents: nil)
        return l
    }

    /// Runs the helper with a relaunch command that records the app it opens and, when that app's version is
    /// `starts`, writes the ready file as a started MetalHorizon does.
    private func runHelper(_ l: Layout, pid: pid_t = 0, starts: String?, extra: [String: String] = [:]) throws -> (Int32, String) {
        let fakeOpen = root.appendingPathComponent("fake-open.sh")
        try """
            #!/bin/bash
            echo "$1" >> '\(l.relaunched.path)'
            v=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist")
            [ "$v" = '\(starts ?? "none")' ] && echo "$v" > '\(l.ready.path)'
            exit 0
            """.write(to: fakeOpen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        let script = l.work.appendingPathComponent("update-helper.sh")
        try UpdateHelper.script.write(to: script, atomically: true, encoding: .utf8)
        var env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                   "MH_UPDATE_APP": l.app.path, "MH_UPDATE_NEW": l.new.path, "MH_UPDATE_WORK": l.work.path,
                   "MH_UPDATE_PID": String(pid), "MH_UPDATE_VERSION": "0.4.1", "MH_UPDATE_OLD_VERSION": "0.4.0",
                   "MH_UPDATE_EXECUTABLE": "MetalHorizon", "MH_UPDATE_READY": l.ready.path, "MH_UPDATE_FAILED": l.failed.path,
                   "MH_UPDATE_LOG": l.log.path, "MH_UPDATE_RELAUNCH": fakeOpen.path, "MH_UPDATE_TIMEOUT": "2",
                   "MH_UPDATE_QUIT_TIMEOUT": "2", "MH_UPDATE_TRASH": l.trash.path]
        env.merge(extra) { _, new in new }
        let (code, out) = try shell("/bin/bash", [script.path], env: env)
        let log = (try? String(contentsOf: l.log, encoding: .utf8)) ?? ""
        return (code, log + out)
    }

    private func relaunches(_ l: Layout) -> [String] {
        ((try? String(contentsOf: l.relaunched, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testHelperSwapsTheAppAndTrashesThePreviousOne() throws {
        let l = try layout()
        // the running app: the helper waits for it to quit first
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["0.6"]
        try running.run()
        let (code, log) = try runHelper(l, pid: running.processIdentifier, starts: "0.4.1")
        XCTAssertEqual(code, 0, log)
        XCTAssertFalse(running.isRunning)
        XCTAssertEqual(version(of: l.app), "0.4.1", log)
        XCTAssertEqual(relaunches(l), [l.app.path])
        XCTAssertEqual(version(of: l.trash.appendingPathComponent("MetalHorizon 0.4.0.app")), "0.4.0", log)
        XCTAssertFalse(fileExists(l.work.path), "the work folder is removed")
        XCTAssertFalse(fileExists(l.failed.path))
        XCTAssertTrue(fileExists(l.other.path), "nothing else is touched")
        XCTAssertTrue(log.contains("MetalHorizon 0.4.1 started; MetalHorizon 0.4.0 is in the Trash"), log)

        // a second update the same way: the Trash already has a "MetalHorizon 0.4.0.app"
        try FileManager.default.removeItem(at: l.app)
        try FileManager.default.removeItem(at: l.relaunched)
        let again = try layout()
        let (code2, log2) = try runHelper(again, starts: "0.4.1")
        XCTAssertEqual(code2, 0, log2)
        XCTAssertEqual(version(of: l.trash.appendingPathComponent("MetalHorizon 0.4.0 (2).app")), "0.4.0", log2)
    }

    func testHelperRollsBackWhenTheNewVersionDoesNotStart() throws {
        let l = try layout()
        let (code, log) = try runHelper(l, starts: nil)
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(version(of: l.app), "0.4.0", log)
        XCTAssertEqual(relaunches(l), [l.app.path, l.app.path], "the new version, then the previous one again")
        XCTAssertEqual(try String(contentsOf: l.failed, encoding: .utf8), "0.4.1\n")
        XCTAssertTrue(log.contains("did not start within 2 s"), log)
        XCTAssertTrue(log.contains("MetalHorizon 0.4.0 is back at"), log)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: l.trash.path), [])
        XCTAssertFalse(fileExists(l.work.path))
    }

    func testHelperPutsTheAppBackWhenTheMoveFails() throws {
        let l = try layout()
        try FileManager.default.removeItem(at: l.new)        // the second move fails
        let (code, log) = try runHelper(l, starts: "0.4.1")
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(version(of: l.app), "0.4.0", log)
        XCTAssertEqual(relaunches(l), [l.app.path])
        XCTAssertEqual(try String(contentsOf: l.failed, encoding: .utf8), "0.4.1\n")
        XCTAssertTrue(log.contains("putting 0.4.0 back"), log)
        XCTAssertFalse(fileExists(l.work.path))

        // the first move fails (a folder the account cannot write to): nothing changes
        let m = try layout()
        try? FileManager.default.removeItem(at: m.relaunched)
        try? FileManager.default.removeItem(at: m.failed)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: m.app.deletingLastPathComponent().path)
        let (code2, log2) = try runHelper(m, starts: "0.4.1")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: m.app.deletingLastPathComponent().path)
        XCTAssertNotEqual(code2, 0)
        XCTAssertEqual(version(of: m.app), "0.4.0", log2)
        XCTAssertEqual(relaunches(m), [m.app.path])
        XCTAssertTrue(log2.contains("nothing was changed"), log2)
    }

    /// Once the app has quit, macOS sends TERM to the helper's process group (seen on this Mac); started as the app
    /// starts it, the helper and what it runs (sleep, mv, open) go on, and the rollback completes.
    func testHelperIgnoresTERMToItsGroup() throws {
        let l = try layout()
        let fakeOpen = root.appendingPathComponent("fake-open.sh")
        try "#!/bin/bash\necho \"$1\" >> '\(l.relaunched.path)'\n".write(to: fakeOpen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        let script = l.work.appendingPathComponent("update-helper.sh")
        try UpdateHelper.script.write(to: script, atomically: true, encoding: .utf8)
        let env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                   "MH_UPDATE_APP": l.app.path, "MH_UPDATE_NEW": l.new.path, "MH_UPDATE_WORK": l.work.path,
                   "MH_UPDATE_VERSION": "0.4.1", "MH_UPDATE_OLD_VERSION": "0.4.0", "MH_UPDATE_READY": l.ready.path,
                   "MH_UPDATE_FAILED": l.failed.path, "MH_UPDATE_LOG": l.log.path, "MH_UPDATE_RELAUNCH": fakeOpen.path,
                   "MH_UPDATE_TIMEOUT": "2", "MH_UPDATE_TRASH": l.trash.path]
        let pid = try UpdateHelper.launch(script, environment: env, log: root.appendingPathComponent("helper.out"))
        for _ in 0..<4 {      // while it waits for the new version to start
            Thread.sleep(forTimeInterval: 0.3)
            kill(-pid, SIGTERM)
            kill(-pid, SIGHUP)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let log = (try? String(contentsOf: l.log, encoding: .utf8)) ?? ""
        XCTAssertEqual(status & 0x7f, 0, "it exited by itself, not by a signal: \(log)")
        XCTAssertEqual(version(of: l.app), "0.4.0", log)
        XCTAssertTrue(log.contains("MetalHorizon 0.4.0 is back at"), log)
        XCTAssertEqual(relaunches(l), [l.app.path, l.app.path])
        XCTAssertFalse(fileExists(l.work.path))
    }

    func testHelperChangesNothingWhileTheAppStillRuns() throws {
        let l = try layout()
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["30"]
        try running.run()
        defer { running.terminate() }
        let (code, log) = try runHelper(l, pid: running.processIdentifier, starts: "0.4.1", extra: ["MH_UPDATE_QUIT_TIMEOUT": "1"])
        XCTAssertNotEqual(code, 0)
        XCTAssertEqual(version(of: l.app), "0.4.0")
        XCTAssertEqual(relaunches(l), [])
        XCTAssertFalse(fileExists(l.failed.path), "it tries again next time")
        XCTAssertTrue(log.contains("did not quit"), log)
    }

    /// The helper is started in a session of its own, with the environment it is given and its output in the log.
    func testHelperStartsDetached() throws {
        let script = root.appendingPathComponent("probe.sh")
        let out = root.appendingPathComponent("probe.out")
        try """
            #!/bin/bash
            echo "printed"
            echo "$$ $(ps -o pgid= -p $$ | tr -d ' ') $MH_PROBE" > '\(out.path)'
            """.write(to: script, atomically: true, encoding: .utf8)
        let log = root.appendingPathComponent("probe.log")
        let pid = try UpdateHelper.launch(script, environment: ["PATH": "/usr/bin:/bin", "MH_PROBE": "passed"], log: log)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let fields = try String(contentsOf: out, encoding: .utf8).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(fields, [String(pid), String(pid), "passed"], "its own process group (session leader)")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "printed\n")

        let env = UpdateHelper.environment(app: URL(fileURLWithPath: "/Applications/MetalHorizon.app"), newApp: root, work: root,
                                           version: "0.4.1", oldVersion: "0.4.0", executable: "MetalHorizon")
        XCTAssertEqual(env["MH_UPDATE_APP"], "/Applications/MetalHorizon.app")
        XCTAssertEqual(env["MH_UPDATE_PID"], String(getpid()))
        XCTAssertNil(env["MH_SUPPORT_DIR"], "the test switches are not passed on to the relaunched app")
        XCTAssertFalse(env.keys.contains { $0.hasPrefix("DYLD_") })
    }

    // MARK: -

    /// Runs async code from a synchronous test (XCTest's throwing helpers do not take async closures).
    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = expectation(description: "async")
        Task {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return try XCTUnwrap(box.result).get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
