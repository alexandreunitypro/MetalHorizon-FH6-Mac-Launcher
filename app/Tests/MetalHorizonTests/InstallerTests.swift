import XCTest
@testable import MetalHorizon

// The installer end to end, in a throwaway folder: the two release tarballs (taken from MH_COMPONENTS_DIR, default
// ~/BlackwellEngine-build; with MH_TEST_DOWNLOAD=1, downloaded from the public release), Apple's licence declined then
// accepted, the shim assembled, and the Play script's dry run.
//   cd app && swift test          MH_TEST_DOWNLOAD=1 swift test
// Only this test accepts Apple's licence (for its own throwaway copy); the app always asks the user.
final class InstallerTests: XCTestCase {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-installer-test-\(getpid())")

    override class func setUp() {
        try? FileManager.default.removeItem(at: root)
        setenv("MH_SUPPORT_DIR", root.path, 1)   // before supportDirectory is first read
        if ProcessInfo.processInfo.environment["MH_TEST_DOWNLOAD"] != nil {
            unsetenv("MH_COMPONENTS_DIR")      // like a new Mac: from the public release over the network
        } else if ProcessInfo.processInfo.environment["MH_COMPONENTS_DIR"] == nil {
            setenv("MH_COMPONENTS_DIR", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BlackwellEngine-build").path, 1)
        }
    }

    override class func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func components() throws -> [String: Component] {
        let json = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("components.json")
        let list = try JSONDecoder().decode([String: [Component]].self, from: Data(contentsOf: json))["components"] ?? []
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    func testInstallEverythingThenPlayDryRun() async throws {
        XCTAssertEqual(supportDirectory.path, Self.root.path)
        let all = try components()
        let engine = try XCTUnwrap(all["engine"]), d3dmetal = try XCTUnwrap(all["d3dmetal"])

        // Blackwell Engine: no licence to accept
        var asked = 0
        try await Installer.install(engine, confirm: { _ in asked += 1; return false }, progress: { _, _ in })
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(engine.isInstalled)
        XCTAssertTrue(fileExists(installedEngineDirectory + "/bin/wine"))
        XCTAssertTrue(fileExists(installedEngineDirectory + "/lib/libgnutls.30.dylib"))

        // D3DMetal: declining installs nothing
        do {
            try await Installer.install(d3dmetal, confirm: { _ in false }, progress: { _, _ in })
            XCTFail("declined licence must stop the install")
        } catch InstallError.declined {}
        XCTAssertFalse(d3dmetal.isInstalled)
        XCTAssertFalse(fileExists(installedD3DMetalDirectory))

        // accepting: the licence shown is Apple's file from the tarball
        var shown = ""
        try await Installer.install(d3dmetal, confirm: { url in
            shown = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string) ?? ""
            return true
        }, progress: { _, _ in })
        XCTAssertTrue(shown.contains("Apple"))
        XCTAssertTrue(d3dmetal.isInstalled)
        let unixHalf = installedD3DMetalDirectory + "/wine/x86_64-unix/d3d12.so"
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: unixHalf), "Apple's .so files must stay links")

        // the shim
        try Installer.prepareShim(engine: installedEngineDirectory, d3dmetal: installedD3DMetalDirectory)
        let setup = Setup(gameDirectory: "", engineDirectory: "", d3dmetalDirectory: "", metalHUD: false)
        XCTAssertTrue(setup.shimReady)
        XCTAssertTrue(setup.engineCheck.ok, setup.engineCheck.text)
        XCTAssertTrue(setup.d3dmetalCheck.ok, setup.d3dmetalCheck.text)
        let apple = [UInt8](try Data(contentsOf: URL(fileURLWithPath: installedD3DMetalDirectory + "/wine/x86_64-windows/d3d12.dll")))
        let copy = [UInt8](try Data(contentsOf: URL(fileURLWithPath: shimDirectory + "/x86_64-windows/apd12.dll")))
        let at = try XCTUnwrap(PEFile.exportNameOffset(copy))
        XCTAssertEqual(String(decoding: copy[at..<at + 9], as: UTF8.self), "apd12.dll")
        XCTAssertEqual(String(decoding: apple[at..<at + 9], as: UTF8.self), "d3d12.dll", "Apple's own file is untouched")
        XCTAssertEqual(zip(apple, copy).filter { $0 != $1 }.count, 2, "only the export name differs (d3 -> ap)")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: shimDirectory + "/x86_64-unix/apd12.so"), unixHalf)

        // Play's dry run with these folders: no STOP, no CrossOver anywhere
        // the dry run starts nothing: a game folder with an empty forzahorizon6.exe is enough
        let game = Self.root.appendingPathComponent("FH6").path
        try FileManager.default.createDirectory(atPath: game, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: game + "/forzahorizon6.exe", contents: Data())
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/metalhorizon-play.sh")
        var env = Setup(gameDirectory: game, metalHUD: false).playEnvironment(resources: URL(fileURLWithPath: "/usr/bin"))
        env["MH_DRY_RUN"] = "1"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        task.environment = env.merging(["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]) { a, _ in a }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, out)
        XCTAssertFalse(out.contains("STOP"), out)
        XCTAssertFalse(out.lowercased().contains("crossover"), out)
        XCTAssertTrue(out.contains("HB_D3D12_REAL=\"Z:" + shimDirectory + "/x86_64-windows/apd12.dll\""), out)
    }
}
