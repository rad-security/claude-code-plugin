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
export {};
