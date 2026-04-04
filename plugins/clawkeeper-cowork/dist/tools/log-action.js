/**
 * clawkeeper_log_action handler
 *
 * Pure structured audit logging. Records each major task step with an
 * action description, involved files (hashed), and classification level.
 * Always logs locally; also reports to the API when connected.
 */
import * as crypto from "node:crypto";
// ── Hash helper ───────────────────────────────────────────────────────
function hashPath(filePath) {
    return crypto.createHash("sha256").update(filePath).digest("hex").slice(0, 8);
}
// ── Handler ───────────────────────────────────────────────────────────
export function logAction(action, files, classification, reporter, config) {
    try {
        // 1. Generate a unique event ID
        const eventId = crypto.randomUUID();
        // 2. Hash file paths — never include raw paths in reported events
        const hashedFiles = (files ?? []).map(hashPath);
        // 3. Build the event payload
        const event = {
            detection_layer: "cowork",
            verdict: "passed",
            severity: "info",
            pattern_name: "audit_log",
            input_hash: crypto
                .createHash("sha256")
                .update(action)
                .digest("hex")
                .slice(0, 8),
            confidence: 100,
            context: {
                tool: "log_action",
                event_id: eventId,
                action,
                files: hashedFiles,
                file_count: (files ?? []).length,
                classification: classification ?? "unclassified",
            },
        };
        // 4. Always log locally (synchronous, best-effort)
        try {
            reporter.logLocal(event);
        }
        catch {
            /* local logging failure should not block response */
        }
        // 5. Report to API (fire-and-forget)
        reporter.report(event);
        // 6. Return result
        return {
            logged: true,
            event_id: eventId,
        };
    }
    catch (err) {
        // Even on error, generate an event_id so the caller has a reference
        const fallbackId = crypto.randomUUID();
        return {
            logged: false,
            event_id: fallbackId,
        };
    }
}
//# sourceMappingURL=log-action.js.map