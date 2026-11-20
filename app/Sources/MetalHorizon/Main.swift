import Foundation

/// `MetalHorizon --mcp` is the MCP server an AI assistant starts (stdio); anything else opens the app.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        }
        // `MetalHorizon --steam-notices-seen <Steam folder> <app id>`: what metalhorizon-steam.sh runs right before it
        // cold-starts the silent Steam client (SteamLaunchNotice: issues #16, #17).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--steam-notices-seen"), args.count > i + 2 {
            let count = SteamLaunchNotice.markSeen(steamRoot: URL(fileURLWithPath: args[i + 1]), appID: Int(args[i + 2]) ?? 2483190)
            print(count > 0 ? "Steam's pre-launch notices recorded as seen (\(count) Steam user\(count == 1 ? "" : "s"))"
                            : "Steam's pre-launch notices: nothing to record")
            exit(0)
        }
        MetalHorizonApp.main()
    }
}
