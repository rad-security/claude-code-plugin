/**
 * Policy engine for the Cowork connector.
 *
 * Evaluates file operations against the active security policy. In local
 * mode (no API key), sensible defaults apply. When connected to the
 * Clawkeeper API, the engine uses the organization's security_level from
 * the shield_policies table.
 */
// ── Classification rank ────────────────────────────────────────────────
const CLASSIFICATION_RANK = {
    public: 0,
    internal: 1,
    confidential: 2,
    restricted: 3,
};
// ── Default policy tables ──────────────────────────────────────────────
/**
 * Default policy matrix used when no API key is configured.
 * Keys: `${classification}:${operation}` → PolicyResult
 */
const DEFAULT_POLICY = {
    // Restricted
    "restricted:read": {
        verdict: "warn",
        guidance: "This file is classified as restricted. Accessing it will be logged. Ensure you have a legitimate need.",
    },
    "restricted:share": {
        verdict: "denied",
        guidance: "Sharing restricted files is not permitted. This file may contain PII, secrets, or key material.",
    },
    "restricted:summarize": {
        verdict: "warn",
        guidance: "Summarizing restricted content may expose sensitive data. Proceed with caution.",
    },
    "restricted:copy": {
        verdict: "denied",
        guidance: "Copying restricted files is not permitted without explicit authorization.",
    },
    // Confidential
    "confidential:read": {
        verdict: "allowed",
        guidance: "Access permitted. This file contains confidential information.",
    },
    "confidential:share": {
        verdict: "warn",
        guidance: "This file is confidential. Verify the recipient is authorized before sharing.",
    },
    "confidential:summarize": {
        verdict: "allowed",
        guidance: "Summarization permitted, but avoid including raw PII in the output.",
    },
    "confidential:copy": {
        verdict: "warn",
        guidance: "Copying confidential files creates additional exposure. Ensure the destination is secure.",
    },
    // Internal
    "internal:read": {
        verdict: "allowed",
        guidance: "Access permitted.",
    },
    "internal:share": {
        verdict: "allowed",
        guidance: "Sharing internal files is permitted within the organization.",
    },
    "internal:summarize": {
        verdict: "allowed",
        guidance: "Summarization permitted.",
    },
    "internal:copy": {
        verdict: "allowed",
        guidance: "Copy permitted.",
    },
    // Public
    "public:read": {
        verdict: "allowed",
        guidance: "No restrictions.",
    },
    "public:share": {
        verdict: "allowed",
        guidance: "No restrictions.",
    },
    "public:summarize": {
        verdict: "allowed",
        guidance: "No restrictions.",
    },
    "public:copy": {
        verdict: "allowed",
        guidance: "No restrictions.",
    },
};
// ── Policy engine ──────────────────────────────────────────────────────
export class PolicyEngine {
    securityLevel = "strict";
    allowedShareDomains = new Set();
    customRules = new Map();
    connected = false;
    /**
     * Update the engine with a policy fetched from the Clawkeeper API.
     * Call this whenever you receive fresh policy data.
     */
    update(policy) {
        this.connected = true;
        this.securityLevel = policy.security_level;
        this.allowedShareDomains.clear();
        if (policy.allowed_share_domains) {
            for (const domain of policy.allowed_share_domains) {
                this.allowedShareDomains.add(domain.toLowerCase());
            }
        }
        this.customRules.clear();
        if (policy.custom_rules) {
            for (const rule of policy.custom_rules) {
                const key = `${rule.classification}:${rule.operation}`;
                this.customRules.set(key, {
                    verdict: rule.verdict,
                    guidance: `Custom policy rule: ${rule.verdict} for ${rule.operation} on ${rule.classification} files.`,
                });
            }
        }
    }
    /** Whether a policy has been loaded from the API. */
    isLoaded() {
        return this.connected;
    }
    /** Return the current security level. */
    getSecurityLevel() {
        return this.securityLevel;
    }
    /** Return the list of allowed external domains (for recipient verification). */
    getAllowedExternalDomains() {
        return Array.from(this.allowedShareDomains);
    }
    /**
     * Evaluate whether an operation on a file with the given classification
     * should be allowed, warned, or denied.
     */
    evaluate(classification, operation) {
        const key = `${classification}:${operation}`;
        // Custom rules from API take highest priority
        const customResult = this.customRules.get(key);
        if (customResult)
            return customResult;
        // If connected to API, use security-level-based evaluation
        if (this.connected) {
            return this.evaluateConnected(classification, operation);
        }
        // Local/default mode — use the static policy table
        return (DEFAULT_POLICY[key] ?? {
            verdict: "allowed",
            guidance: "No policy applies to this operation.",
        });
    }
    // ── Connected mode evaluation ──────────────────────────────────────
    evaluateConnected(classification, operation) {
        const rank = CLASSIFICATION_RANK[classification] ?? 0;
        switch (this.securityLevel) {
            case "paranoid":
                return this.evaluateParanoid(classification, operation, rank);
            case "strict":
                return this.evaluateStrict(classification, operation, rank);
            case "moderate":
                return this.evaluateModerate(classification, operation, rank);
            case "minimal":
                return this.evaluateMinimal(classification, operation, rank);
            default:
                // Unknown level — fall back to strict
                return this.evaluateStrict(classification, operation, rank);
        }
    }
    /**
     * Paranoid: warn on any PII detection, deny sharing to unknown domains.
     * Effectively denies most operations on anything above public.
     */
    evaluateParanoid(classification, operation, rank) {
        if (rank >= CLASSIFICATION_RANK.restricted) {
            return {
                verdict: "denied",
                guidance: `[Paranoid] All operations on restricted files are denied.`,
            };
        }
        if (rank >= CLASSIFICATION_RANK.confidential) {
            if (operation === "share" || operation === "copy") {
                return {
                    verdict: "denied",
                    guidance: `[Paranoid] Sharing or copying confidential files is denied.`,
                };
            }
            return {
                verdict: "warn",
                guidance: `[Paranoid] Confidential file access is logged and flagged for review.`,
            };
        }
        if (rank >= CLASSIFICATION_RANK.internal) {
            if (operation === "share") {
                return {
                    verdict: "warn",
                    guidance: `[Paranoid] Sharing internal files requires verification.`,
                };
            }
            return {
                verdict: "allowed",
                guidance: `[Paranoid] Internal file ${operation} is permitted.`,
            };
        }
        return {
            verdict: "allowed",
            guidance: `No restrictions on public files.`,
        };
    }
    /**
     * Strict: warn on any PII, deny sharing to unknown domains.
     */
    evaluateStrict(classification, operation, rank) {
        if (rank >= CLASSIFICATION_RANK.restricted) {
            if (operation === "read" || operation === "summarize") {
                return {
                    verdict: "warn",
                    guidance: `[Strict] Restricted file access will be logged. Proceed only if authorized.`,
                };
            }
            return {
                verdict: "denied",
                guidance: `[Strict] ${operation} on restricted files is denied.`,
            };
        }
        if (rank >= CLASSIFICATION_RANK.confidential) {
            if (operation === "share") {
                return {
                    verdict: "warn",
                    guidance: `[Strict] Verify the recipient is authorized before sharing confidential files.`,
                };
            }
            return {
                verdict: "allowed",
                guidance: `[Strict] Confidential file ${operation} is permitted.`,
            };
        }
        return {
            verdict: "allowed",
            guidance: `[Strict] ${classification} file ${operation} is permitted.`,
        };
    }
    /**
     * Moderate: log PII, warn on unknown domains.
     */
    evaluateModerate(classification, operation, rank) {
        if (rank >= CLASSIFICATION_RANK.restricted) {
            if (operation === "share" || operation === "copy") {
                return {
                    verdict: "warn",
                    guidance: `[Moderate] Sharing or copying restricted files will be logged. Verify authorization.`,
                };
            }
            return {
                verdict: "allowed",
                guidance: `[Moderate] Restricted file ${operation} is permitted but logged.`,
            };
        }
        if (rank >= CLASSIFICATION_RANK.confidential && operation === "share") {
            return {
                verdict: "allowed",
                guidance: `[Moderate] Sharing confidential files is permitted. Activity is logged.`,
            };
        }
        return {
            verdict: "allowed",
            guidance: `[Moderate] ${classification} file ${operation} is permitted.`,
        };
    }
    /**
     * Minimal: log everything, deny nothing.
     */
    evaluateMinimal(classification, operation, _rank) {
        return {
            verdict: "allowed",
            guidance: `[Minimal] ${classification} file ${operation} is permitted. Activity is logged.`,
        };
    }
}
//# sourceMappingURL=policy-engine.js.map