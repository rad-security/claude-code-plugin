/**
 * Event reporter for the Clawkeeper Cowork MCP server.
 *
 * Collects security events and:
 *   - Always writes to a local JSONL audit log ($dataDir/audit-YYYY-MM-DD.jsonl)
 *   - Optionally sends batches to the Clawkeeper API when an API key is configured
 *
 * Flush triggers: every 30 seconds, or when the queue reaches 10 events.
 */
import type { CoworkConfig } from "./config.js";
export interface CoworkEventContext {
    tool: string;
    file_path?: string;
    file_hash?: string;
    classification?: string;
    detected_types?: string[];
    operation?: string;
    policy_result?: string;
    recipient?: string;
    domain?: string;
    action?: string;
    event_id?: string;
    files?: string[];
    file_count?: number;
    has_legal_markers?: boolean;
    [key: string]: unknown;
}
export interface CoworkEvent {
    hostname?: string;
    detection_layer: "cowork";
    verdict: "passed" | "warned" | "blocked";
    severity: "critical" | "high" | "medium" | "low" | "info";
    security_level?: string;
    pattern_name: string;
    input_hash: string;
    confidence: number;
    context: CoworkEventContext;
}
export declare class CoworkReporter {
    private config;
    private queue;
    private timer;
    private layerRejectionWarned;
    constructor(config: CoworkConfig);
    /** Add an event to the queue. Also writes to local JSONL immediately. */
    report(event: CoworkEvent): void;
    /** Start the periodic flush timer. */
    start(): void;
    /** Flush remaining events and stop the timer. */
    stop(): Promise<void>;
    /** Write a single event to the local JSONL audit log. */
    logLocal(event: CoworkEvent): void;
    private flush;
}
