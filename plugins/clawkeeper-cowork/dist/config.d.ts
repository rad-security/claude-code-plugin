/**
 * Configuration loader for the Clawkeeper Cowork MCP server.
 *
 * Resolution order for API key:
 *   1. CLAWKEEPER_API_KEY env var
 *   2. File at $dataDir/api_key
 *   3. Empty string (local-only mode — events are only written to local JSONL)
 */
export interface CoworkConfig {
    /** API key for clawkeeper.dev. Empty string = local-only mode. */
    apiKey: string;
    /** Base URL for the Clawkeeper API. */
    apiUrl: string;
    /** Local data directory for audit logs and cached config. */
    dataDir: string;
    /** Hostname reported with events. */
    hostname: string;
}
export declare function loadConfig(): CoworkConfig;
