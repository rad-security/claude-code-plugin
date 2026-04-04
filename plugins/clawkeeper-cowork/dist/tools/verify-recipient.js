/**
 * clawkeeper_verify_recipient handler
 *
 * Verifies whether an external recipient (email/domain) is allowed
 * before Cowork sends data. Checks against the org's allowed domain
 * list and considers the classification of the data being sent.
 */
import * as crypto from "node:crypto";
// ── Hash helper ───────────────────────────────────────────────────────
function hashRecipient(recipient) {
    return crypto
        .createHash("sha256")
        .update(recipient)
        .digest("hex")
        .slice(0, 8);
}
// ── Domain extraction ─────────────────────────────────────────────────
/**
 * Extract domain from a recipient string. Supports:
 *   - Email addresses: "user@example.com" → "example.com"
 *   - Bare domains: "example.com" → "example.com"
 */
function extractDomain(recipient) {
    const trimmed = recipient.trim().toLowerCase();
    const atIndex = trimmed.indexOf("@");
    return atIndex >= 0 ? trimmed.slice(atIndex + 1) : trimmed;
}
/**
 * Check whether `domain` matches an entry in the allowed list.
 * Supports exact match and subdomain match (e.g. "sub.example.com"
 * matches allowed entry "example.com").
 */
function domainMatches(domain, allowedDomain) {
    const d = domain.toLowerCase();
    const a = allowedDomain.toLowerCase();
    return d === a || d.endsWith(`.${a}`);
}
// ── Handler ───────────────────────────────────────────────────────────
export function verifyRecipient(recipient, dataClassification, policy, reporter, config) {
    try {
        const domain = extractDomain(recipient);
        const classification = dataClassification ?? "public";
        // 1. If no policy loaded (local mode), allow with advisory note
        if (!policy.isLoaded()) {
            const result = {
                allowed: true,
                domain,
                policy_note: "No domain policy configured. Connect to clawkeeper.dev to set allowed domains.",
            };
            reporter.report({
                detection_layer: "cowork",
                verdict: "passed",
                severity: "low",
                security_level: policy.getSecurityLevel(),
                pattern_name: "recipient_verification",
                input_hash: hashRecipient(recipient),
                confidence: 50,
                context: {
                    tool: "verify_recipient",
                    domain,
                    data_classification: classification,
                    policy_loaded: false,
                    allowed: true,
                },
            });
            return result;
        }
        // 2. Check allowed external domains from policy
        const allowedDomains = policy.getAllowedExternalDomains();
        let domainAllowed;
        let policyNote;
        if (allowedDomains.length === 0) {
            // Empty list = all domains allowed
            domainAllowed = true;
            policyNote = "External sharing allowed (no domain restrictions configured).";
        }
        else {
            // Check domain against allowed list
            const matched = allowedDomains.some((allowed) => domainMatches(domain, allowed));
            if (matched) {
                domainAllowed = true;
                policyNote = `External sharing allowed for ${domain}.`;
            }
            else {
                domainAllowed = false;
                policyNote = `Domain ${domain} is not in the approved domain list. External sharing denied.`;
            }
        }
        // 3. If sending restricted/confidential data to unapproved domain, deny
        if (!domainAllowed &&
            (classification === "restricted" || classification === "confidential")) {
            const result = {
                allowed: false,
                domain,
                policy_note: `Cannot send ${classification} data to unapproved domain ${domain}. Contact your admin to add this domain.`,
            };
            reporter.report({
                detection_layer: "cowork",
                verdict: "blocked",
                severity: "high",
                security_level: policy.getSecurityLevel(),
                pattern_name: "recipient_verification",
                input_hash: hashRecipient(recipient),
                confidence: 95,
                context: {
                    tool: "verify_recipient",
                    domain,
                    data_classification: classification,
                    policy_loaded: true,
                    allowed: false,
                    reason: "unapproved_domain_sensitive_data",
                },
            });
            return result;
        }
        // 4. Even for non-sensitive data, deny if domain is not on the list
        //    (when a list is configured)
        if (!domainAllowed) {
            const result = {
                allowed: false,
                domain,
                policy_note: policyNote,
            };
            reporter.report({
                detection_layer: "cowork",
                verdict: "blocked",
                severity: "medium",
                security_level: policy.getSecurityLevel(),
                pattern_name: "recipient_verification",
                input_hash: hashRecipient(recipient),
                confidence: 90,
                context: {
                    tool: "verify_recipient",
                    domain,
                    data_classification: classification,
                    policy_loaded: true,
                    allowed: false,
                    reason: "unapproved_domain",
                },
            });
            return result;
        }
        // 5. Domain is allowed — report and return
        reporter.report({
            detection_layer: "cowork",
            verdict: "passed",
            severity: "low",
            security_level: policy.getSecurityLevel(),
            pattern_name: "recipient_verification",
            input_hash: hashRecipient(recipient),
            confidence: 95,
            context: {
                tool: "verify_recipient",
                domain,
                data_classification: classification,
                policy_loaded: true,
                allowed: true,
            },
        });
        return {
            allowed: true,
            domain,
            policy_note: policyNote,
        };
    }
    catch (err) {
        const message = err instanceof Error ? err.message : "Unknown error during recipient verification";
        // Graceful degradation — deny on error for safety
        return {
            allowed: false,
            domain: extractDomain(recipient),
            policy_note: `Verification error — denying by default. (${message})`,
        };
    }
}
//# sourceMappingURL=verify-recipient.js.map