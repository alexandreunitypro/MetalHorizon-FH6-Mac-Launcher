import Foundation

/// `MetalHorizon --mcp` is the MCP server an AI assistant starts (stdio); anything else opens the app.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        }
        MetalHorizonApp.main()
    }
}
