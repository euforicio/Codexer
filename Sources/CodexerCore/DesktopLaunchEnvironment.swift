import Foundation

enum DesktopLaunchEnvironment {
    static func sanitized(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        // These values select app state, another app-server, or injected runtime
        // behavior. Each launch supplies its own validated provider identity.
        for key in [
            "CODEX_HOME",
            "CODEX_CLI_PATH",
            "CODEX_ELECTRON_USER_DATA_PATH",
            "CODEX_ELECTRON_AGENT_RUN_ID",
            "CODEX_APP_SERVER_WS_URL",
            "CODEX_APP_SERVER_USE_LOCAL_DAEMON",
            "CODEX_APP_SERVER_FORCE_CLI",
            "CLAUDE_USER_DATA_DIR",
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR",
            "ELECTRON_RUN_AS_NODE",
            "NODE_OPTIONS",
            "NODE_PATH"
        ] {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}
