/**
 * clawkeeper_check_sensitivity handler
 *
 * Classifies a file's sensitivity before Cowork reads, writes, deletes, or
 * shares it. Returns the classification level, any PII types found, the
 * policy verdict, and human-readable guidance for Claude.
 */
import * as crypto from "node:crypto";
import { classifyFile } from "../detection/file-classifier.js";
// ── Guidance builders ─────────────────────────────────────────────────
function buildGuidance(classification, policyResult, detectedTypes) {
    if (classification === "public" && policyResult.verdict === "allowed") {
        return "No sensitive data detected.";
    }
    if (policyResult.verdict === "denied") {
        return `This file is classified as ${classification} per org policy. Access denied for this operation.`;
    }
    // warn or allowed with sensitive data
    const typesList = detectedTypes.length > 0
        ? detectedTypes.map(humaniseType).join(", ")
        : classification;
    if (policyResult.verdict === "warn") {
        return `This file contains PII (${typesList}). Avoid including personal data in external outputs.`;
    }
    // allowed but non-public
    if (classification === "internal") {
        return `This file is classified as internal. Handle according to org guidelines.`;
    }
    return `This file contains sensitive data (${typesList}). Exercise caution when processing.`;
}
/** Turn snake_case pattern names into something readable. */
function humaniseType(t) {
    return t
        .replace(/_/g, " ")
        .replace(/\b(ssn|cc|dob|dl)\b/gi, (m) => m.toUpperCase());
}
// ── Hash helper ───────────────────────────────────────────────────────
function hashPath(filePath) {
    return crypto.createHash("sha256").update(filePath).digest("hex").slice(0, 8);
}
// ── Handler ───────────────────────────────────────────────────────────
export function checkSensitivity(filePath, operation, policy, reporter, config) {
    try {
        // 1. Classify the file (extension + first-10KB PII scan)
        const fileResult = classifyFile(filePath);
        // 2. Evaluate against org policy
        const policyResult = policy.evaluate(fileResult.classification, operation);
        // 3. Build guidance string
        const guidance = buildGuidance(fileResult.classification, policyResult, fileResult.detectedTypes);
        // 4. Report event (fire-and-forget — never block the response)
        reporter.report({
            detection_layer: "cowork",
            verdict: policyResult.verdict === "allowed" ? "passed" : policyResult.verdict === "warn" ? "warned" : "blocked",
            severity: policyResult.verdict === "denied" ? "high" : policyResult.verdict === "warn" ? "medium" : "low",
            security_level: policy.getSecurityLevel(),
            pattern_name: "file_sensitivity_check",
            input_hash: hashPath(filePath),
            confidence: 90,
            context: {
                tool: "check_sensitivity",
                file_hash: hashPath(filePath),
                classification: fileResult.classification,
                detected_types: fileResult.detectedTypes,
                operation,
                policy_result: policyResult.verdict,
            },
        });
        // 5. Return result
        return {
            classification: fileResult.classification,
            contains: fileResult.detectedTypes,
            policy_result: policyResult.verdict,
            guidance,
        };
    }
    catch (err) {
        // Graceful degradation — never throw; return a safe default
        const message = err instanceof Error ? err.message : "Unknown error during sensitivity check";
        return {
            classification: "internal",
            contains: [],
            policy_result: "warn",
            guidance: `Unable to fully classify file — treating as internal. (${message})`,
        };
    }
}
//# sourceMappingURL=check-sensitivity.js.map