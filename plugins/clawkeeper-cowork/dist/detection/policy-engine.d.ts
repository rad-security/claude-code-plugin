/**
 * Policy engine for the Cowork connector.
 *
 * Evaluates file operations against the active security policy. In local
 * mode (no API key), sensible defaults apply. When connected to the
 * Clawkeeper API, the engine uses the organization's security_level from
 * the shield_policies table.
 */
export interface PolicyResult {
    /** Whether the operation is allowed, warned, or denied. */
    verdict: "allowed" | "warn" | "denied";
    /** Human-readable guidance explaining the decision. */
    guidance: string;
}
export interface CoworkPolicy {
    security_level: SecurityLevel;
    allowed_share_domains?: string[];
    custom_rules?: PolicyRule[];
}
export type SecurityLevel = "paranoid" | "strict" | "moderate" | "minimal";
interface PolicyRule {
    classification: string;
    operation: string;
    verdict: "allowed" | "warn" | "denied";
}
export declare class PolicyEngine {
    private securityLevel;
    private allowedShareDomains;
    private customRules;
    private connected;
    /**
     * Update the engine with a policy fetched from the Clawkeeper API.
     * Call this whenever you receive fresh policy data.
     */
    update(policy: CoworkPolicy): void;
    /** Whether a policy has been loaded from the API. */
    isLoaded(): boolean;
    /** Return the current security level. */
    getSecurityLevel(): string;
    /** Return the list of allowed external domains (for recipient verification). */
    getAllowedExternalDomains(): string[];
    /**
     * Evaluate whether an operation on a file with the given classification
     * should be allowed, warned, or denied.
     */
    evaluate(classification: string, operation: string): PolicyResult;
    private evaluateConnected;
    /**
     * Paranoid: warn on any PII detection, deny sharing to unknown domains.
     * Effectively denies most operations on anything above public.
     */
    private evaluateParanoid;
    /**
     * Strict: warn on any PII, deny sharing to unknown domains.
     */
    private evaluateStrict;
    /**
     * Moderate: log PII, warn on unknown domains.
     */
    private evaluateModerate;
    /**
     * Minimal: log everything, deny nothing.
     */
    private evaluateMinimal;
}
export {};
