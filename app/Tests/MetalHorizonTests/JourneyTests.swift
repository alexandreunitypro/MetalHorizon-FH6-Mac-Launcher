import XCTest
@testable import MetalHorizon

final class JourneyTests: XCTestCase {
    /// An Xbox copy already on the Mac or on an external disk is found without a folder dialog.
    func testDetectsAnExistingXboxCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mh-detect-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home"), volumes = root.appendingPathComponent("Volumes")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volumes.appendingPathComponent(".timemachine"), withIntermediateDirectories: true)
        XCTAssertNil(Setup.detectXboxGame(home: home.path, volumes: volumes.path))

        // a folder with the game but without its package is not a usable copy
        let disk = volumes.appendingPathComponent("Games SSD/FH6")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: disk.path + "/forzahorizon6.exe", contents: Data())
        XCTAssertNil(Setup.detectXboxGame(home: home.path, volumes: volumes.path))

        FileManager.default.createFile(atPath: disk.path + "/.xodus-streaming.msixvc", contents: Data())
        XCTAssertEqual(Setup.detectXboxGame(home: home.path, volumes: volumes.path), disk.path)

        // the home folder comes first
        let local = home.appendingPathComponent("Games/Forza Horizon 6")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: local.path + "/forzahorizon6.exe", contents: Data())
        FileManager.default.createFile(atPath: local.path + "/.xodus-streaming.msixvc", contents: Data())
        XCTAssertEqual(Setup.detectXboxGame(home: home.path, volumes: volumes.path), local.path)
    }
}
