/**
 * Configuration loader for the Clawkeeper Cowork MCP server.
 *
 * Resolution order for API key:
 *   1. CLAWKEEPER_API_KEY env var
 *   2. File at $dataDir/api_key
 *   3. Empty string (local-only mode — events are only written to local JSONL)
 */
import { readFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir, hostname } from "node:os";
function resolveDataDir() {
    const envDir = process.env.CLAWKEEPER_DATA_DIR;
    if (envDir)
        return envDir;
    return join(homedir(), ".clawkeeper-cowork");
}
function resolveApiKey(dataDir) {
    // 1. Environment variable
    const envKey = process.env.CLAWKEEPER_API_KEY;
    if (envKey && envKey.trim().length > 0) {
        return envKey.trim();
    }
    // 2. Key file in data dir
    const keyFile = join(dataDir, "api_key");
    if (existsSync(keyFile)) {
        try {
            const contents = readFileSync(keyFile, "utf-8").trim();
            if (contents.length > 0)
                return contents;
        }
        catch {
            // Fall through to empty string
        }
    }
    // 3. Local-only mode
    return "";
}
export function loadConfig() {
    const dataDir = resolveDataDir();
    // Ensure data directory exists
    if (!existsSync(dataDir)) {
        mkdirSync(dataDir, { recursive: true });
    }
    const apiKey = resolveApiKey(dataDir);
    const apiUrl = process.env.CLAWKEEPER_API_URL?.replace(/\/+$/, "") ||
        "https://clawkeeper.dev/api/v1";
    return {
        apiKey,
        apiUrl,
        dataDir,
        hostname: hostname(),
    };
}
//# sourceMappingURL=config.js.map