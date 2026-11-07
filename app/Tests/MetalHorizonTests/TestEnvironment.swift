import Foundation

/// One throwaway support folder for the whole test run, set before anything reads `supportDirectory` (a global that
/// is fixed on first use), so no test touches the real ~/Library/Application Support/MetalHorizon.
enum TestEnvironment {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-test-\(getpid())")
    private static var done = false

    static func ensure() {
        guard !done else { return }
        done = true
        try? FileManager.default.removeItem(at: root)
        setenv("MH_SUPPORT_DIR", root.path, 1)
        setenv("MH_LOG_DIR", root.appendingPathComponent("Logs").path, 1)   // before logDirectory is first read
        if ProcessInfo.processInfo.environment["MH_TEST_DOWNLOAD"] != nil {
            unsetenv("MH_COMPONENTS_DIR")      // like a new Mac: from the public release over the network
        } else if ProcessInfo.processInfo.environment["MH_COMPONENTS_DIR"] == nil {
            setenv("MH_COMPONENTS_DIR", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BlackwellEngine-build").path, 1)
        }
        atexit { try? FileManager.default.removeItem(at: TestEnvironment.root) }
    }
}
