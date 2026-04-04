/**
 * clawkeeper_classify_data handler
 *
 * Classifies a data snippet for sensitivity before Cowork processes or
 * shares it. Detects PII patterns and legal markers, evaluates against
 * org policy, and returns classification + guidance.
 */
import * as crypto from "node:crypto";
import { scanForPII, classifyFromPII } from "../detection/pii-patterns.js";
// ── Legal marker strings ──────────────────────────────────────────────
const LEGAL_MARKERS = ["CONFIDENTIAL", "PRIVILEGED", "ATTORNEY-CLIENT"];
// ── Guidance builders ─────────────────────────────────────────────────
function buildGuidance(classification, policyResult, detectedTypes) {
    if (classification === "public" && policyResult.verdict === "allowed") {
        return "No sensitive data detected in this content.";
    }
    if (policyResult.verdict === "denied") {
        return `This data is classified as ${classification} per org policy. Processing denied.`;
    }
    const typesList = detectedTypes.length > 0
        ? detectedTypes.map(humaniseType).join(", ")
        : classification;
    if (policyResult.verdict === "warn") {
        if (classification === "restricted") {
            return `This data contains highly sensitive information (${typesList}). Do not include in external communications or store in unencrypted files.`;
        }
        return `This data contains PII (${typesList}). Avoid including personal data in external outputs.`;
    }
    // allowed but non-public
    if (classification === "internal") {
        return "This data contains internal markers. Handle according to org guidelines.";
    }
    return `This data contains sensitive information (${typesList}). Exercise caution when processing.`;
}
function humaniseType(t) {
    return t
        .replace(/_/g, " ")
        .replace(/\b(ssn|cc|dob|dl)\b/gi, (m) => m.toUpperCase());
}
// ── Hash helper ───────────────────────────────────────────────────────
function hashContent(content) {
    return crypto.createHash("sha256").update(content).digest("hex").slice(0, 8);
}
// ── Handler ───────────────────────────────────────────────────────────
export function classifyData(contentPreview, context, policy, reporter, config) {
    try {
        // 1. Run PII pattern detection on the content preview
        const matches = scanForPII(contentPreview);
        // 2. Check for legal markers via simple includes
        const upperContent = contentPreview.toUpperCase();
        const hasLegalMarkers = LEGAL_MARKERS.some((marker) => upperContent.includes(marker));
        // 3. Classify from PII matches
        let classification = classifyFromPII(matches);
        // Bump to at least "internal" if legal markers are present
        if (hasLegalMarkers && classification === "public") {
            classification = "internal";
        }
        // 4. Evaluate against org policy (operation = "process" for data classification)
        const policyResult = policy.evaluate(classification, "process");
        // Collect detected type names
        const detectedTypes = matches.map((m) => m.type);
        // 5. Build guidance
        const guidance = buildGuidance(classification, policyResult, detectedTypes);
        // 6. Report event (fire-and-forget)
        reporter.report({
            detection_layer: "cowork",
            verdict: policyResult.verdict === "allowed" ? "passed" : policyResult.verdict === "warn" ? "warned" : "blocked",
            severity: classification === "restricted" ? "high" : classification === "confidential" ? "medium" : "low",
            security_level: policy.getSecurityLevel(),
            pattern_name: "data_classification",
            input_hash: hashContent(contentPreview),
            confidence: matches.length > 0 ? 95 : 50,
            context: {
                tool: "classify_data",
                classification,
                detected_types: detectedTypes,
                has_legal_markers: hasLegalMarkers,
                usage_context: context ?? "not specified",
                policy_result: policyResult.verdict,
            },
        });
        // 7. Return result
        return {
            classification,
            detected_types: detectedTypes,
            policy_result: policyResult.verdict,
            guidance,
        };
    }
    catch (err) {
        const message = err instanceof Error ? err.message : "Unknown error during data classification";
        return {
            classification: "internal",
            detected_types: [],
            policy_result: "warn",
            guidance: `Unable to fully classify data — treating as internal. (${message})`,
        };
    }
}
//# sourceMappingURL=classify-data.js.map