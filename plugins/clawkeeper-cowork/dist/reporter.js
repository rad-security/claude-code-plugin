/**
 * Event reporter for the Clawkeeper Cowork MCP server.
 *
 * Collects security events and:
 *   - Always writes to a local JSONL audit log ($dataDir/audit-YYYY-MM-DD.jsonl)
 *   - Optionally sends batches to the Clawkeeper API when an API key is configured
 *
 * Flush triggers: every 30 seconds, or when the queue reaches 10 events.
 */
import { appendFileSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
// ── Reporter ─────────────────────────────────────────────────────────────
const FLUSH_INTERVAL_MS = 30_000;
const FLUSH_THRESHOLD = 10;
export class CoworkReporter {
    config;
    queue = [];
    timer = null;
    layerRejectionWarned = false;
    constructor(config) {
        this.config = config;
    }
    /** Add an event to the queue. Also writes to local JSONL immediately. */
    report(event) {
        this.logLocal(event);
        this.queue.push(event);
        // Flush immediately if API key is present — don't wait for batch threshold
        // or timer. MCP tool calls are infrequent, so each event matters.
        if (this.config.apiKey) {
            void this.flush();
        }
    }
    /** Start the periodic flush timer. */
    start() {
        if (this.timer)
            return;
        this.timer = setInterval(() => {
            void this.flush();
        }, FLUSH_INTERVAL_MS);
        // Allow the process to exit even if the timer is running
        if (this.timer && typeof this.timer === "object" && "unref" in this.timer) {
            this.timer.unref();
        }
    }
    /** Flush remaining events and stop the timer. */
    async stop() {
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
        await this.flush();
    }
    /** Write a single event to the local JSONL audit log. */
    logLocal(event) {
        const now = new Date();
        const dateStr = now.toISOString().slice(0, 10); // YYYY-MM-DD
        const logPath = join(this.config.dataDir, `audit-${dateStr}.jsonl`);
        const dir = dirname(logPath);
        if (!existsSync(dir)) {
            mkdirSync(dir, { recursive: true });
        }
        const record = {
            timestamp: now.toISOString(),
            ...event,
        };
        try {
            appendFileSync(logPath, JSON.stringify(record) + "\n", "utf-8");
        }
        catch (err) {
            // Best-effort — don't crash the server over a log write failure
            console.error("[clawkeeper] Failed to write local audit log:", err);
        }
    }
    // ── Private ──────────────────────────────────────────────────────────
    async flush() {
        if (this.queue.length === 0)
            return;
        // Drain the queue
        const batch = this.queue.splice(0);
        // If no API key, we already wrote to local JSONL; nothing else to do
        if (!this.config.apiKey)
            return;
        // If we already got a 400 for invalid detection_layer, don't retry
        if (this.layerRejectionWarned)
            return;
        try {
            const url = `${this.config.apiUrl}/shield/events`;
            // Inject hostname into every event (required by the API)
            const enrichedBatch = batch.map((e) => ({
                ...e,
                hostname: e.hostname || this.config.hostname,
            }));
            const response = await fetch(url, {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    Authorization: `Bearer ${this.config.apiKey}`,
                },
                body: JSON.stringify({ events: enrichedBatch }),
            });
            if (response.ok)
                return;
            if (response.status === 400) {
                const body = await response.json().catch(() => null);
                const msg = body && typeof body === "object" && "error" in body
                    ? body.error
                    : "Unknown 400 error";
                // The API may reject "cowork" as an invalid detection_layer.
                // Log once and suppress future attempts so we don't spam.
                if (!this.layerRejectionWarned) {
                    console.error(`[clawkeeper] API rejected event batch (400): ${msg}. ` +
                        "Remote reporting disabled for this session — events will still be logged locally.");
                    this.layerRejectionWarned = true;
                }
                return;
            }
            // Non-400 failures: log and re-queue for retry on next flush
            console.error(`[clawkeeper] API returned ${response.status} — ${batch.length} events will be retried.`);
            this.queue.unshift(...batch);
        }
        catch (err) {
            // Network error — re-queue for retry
            console.error("[clawkeeper] Failed to send events:", err);
            this.queue.unshift(...batch);
        }
    }
}
//# sourceMappingURL=reporter.js.map