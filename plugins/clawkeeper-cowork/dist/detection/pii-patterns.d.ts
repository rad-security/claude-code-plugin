/**
 * PII detection patterns and classification engine for the Cowork connector.
 *
 * Scans text for personally identifiable information, secrets, and
 * sensitive data patterns. Returns typed match results and an overall
 * classification level that feeds into the policy engine.
 */
export interface PiiMatch {
    type: string;
    count: number;
}
export declare const PII_PATTERNS: Record<string, RegExp>;
/**
 * Run all PII patterns against the given text and return matches with counts.
 * Only patterns that match at least once are included.
 */
export declare function scanForPII(text: string): PiiMatch[];
/**
 * Derive a classification level from PII scan results.
 *
 * Hierarchy (highest wins):
 *   restricted  > confidential > internal > public
 */
export declare function classifyFromPII(matches: PiiMatch[]): "restricted" | "confidential" | "internal" | "public";
