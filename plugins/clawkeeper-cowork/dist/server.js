#!/usr/bin/env node
/**
 * Clawkeeper Security MCP Server — entry point.
 *
 * Exposes four security tools to Claude via the Model Context Protocol:
 *   1. clawkeeper_check_sensitivity  — file sensitivity classification
 *   2. clawkeeper_classify_data      — PII/secret scan of data snippets
 *   3. clawkeeper_log_action         — structured audit logging
 *   4. clawkeeper_verify_recipient   — external sharing policy check
 *
 * Runs over stdio transport for use with Claude Code / Cowork.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { loadConfig } from "./config.js";
import { CoworkReporter } from "./reporter.js";
import { PolicyEngine } from "./detection/policy-engine.js";
// ── Bootstrap ────────────────────────────────────────────────────────────
const config = loadConfig();
const reporter = new CoworkReporter(config);
const policyEngine = new PolicyEngine();
const server = new McpServer({
    name: "clawkeeper-security",
    version: "1.0.0",
});
// ── Tool registrations ───────────────────────────────────────────────────
server.tool("clawkeeper_check_sensitivity", "Check file sensitivity before reading, writing, or sharing. Returns classification (public/internal/confidential/restricted) and policy verdict.", {
    file_path: z.string().describe("Absolute path to the file"),
    operation: z.enum(["read", "write", "delete", "share"]).describe("Intended operation"),
}, async (args) => {
    const { checkSensitivity } = await import("./tools/check-sensitivity.js");
    const result = checkSensitivity(args.file_path, args.operation, policyEngine, reporter, config);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
server.tool("clawkeeper_classify_data", "Classify a data snippet for PII, secrets, and sensitive content before processing or sharing.", {
    content_preview: z.string().describe("The text content to classify (first 10KB recommended)"),
    context: z.string().optional().describe("What the data will be used for"),
}, async (args) => {
    const { classifyData } = await import("./tools/classify-data.js");
    const result = classifyData(args.content_preview, args.context, policyEngine, reporter, config);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
server.tool("clawkeeper_log_action", "Log a structured audit event for a task step. Records action, files involved, and classification.", {
    action: z.string().describe("Description of the action being performed"),
    files: z.array(z.string()).optional().describe("File paths involved in the action"),
    classification: z.string().optional().describe("Classification level of the data involved"),
}, async (args) => {
    const { logAction } = await import("./tools/log-action.js");
    const result = logAction(args.action, args.files, args.classification, reporter, config);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
server.tool("clawkeeper_verify_recipient", "Check whether sharing data with an external recipient (email, domain) is allowed by policy.", {
    recipient: z.string().describe("The recipient identifier (email address or domain)"),
    data_classification: z.string().optional().describe("Classification of the data being shared"),
}, async (args) => {
    const { verifyRecipient } = await import("./tools/verify-recipient.js");
    const result = verifyRecipient(args.recipient, args.data_classification, policyEngine, reporter, config);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
// ── Policy sync ──────────────────────────────────────────────────────────
let policySyncTimer = null;
async function syncPolicy() {
    if (!config.apiKey)
        return;
    try {
        const url = `${config.apiUrl}/shield/policy`;
        const res = await fetch(url, {
            headers: { Authorization: `Bearer ${config.apiKey}` },
        });
        if (!res.ok)
            return;
        const data = (await res.json());
        const policyData = {
            security_level: data.security_level ?? "strict",
            allowed_share_domains: data.allowed_external_domains,
        };
        policyEngine.update(policyData);
    }
    catch {
        // Silently continue with cached policy
    }
}
// ── Start ────────────────────────────────────────────────────────────────
async function main() {
    reporter.start();
    // Initial policy fetch, then refresh every 60s
    await syncPolicy();
    if (config.apiKey) {
        policySyncTimer = setInterval(() => {
            void syncPolicy();
        }, 60_000);
        if (policySyncTimer && typeof policySyncTimer === "object" && "unref" in policySyncTimer) {
            policySyncTimer.unref();
        }
    }
    const transport = new StdioServerTransport();
    await server.connect(transport);
    // Graceful shutdown
    const shutdown = async () => {
        if (policySyncTimer)
            clearInterval(policySyncTimer);
        await reporter.stop();
        process.exit(0);
    };
    process.on("SIGINT", () => void shutdown());
    process.on("SIGTERM", () => void shutdown());
}
main().catch((err) => {
    console.error("[clawkeeper] Fatal:", err);
    process.exit(1);
});
//# sourceMappingURL=server.js.map