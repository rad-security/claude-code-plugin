/**
 * PII detection patterns and classification engine for the Cowork connector.
 *
 * Scans text for personally identifiable information, secrets, and
 * sensitive data patterns. Returns typed match results and an overall
 * classification level that feeds into the policy engine.
 */
// ── Pattern definitions ────────────────────────────────────────────────
export const PII_PATTERNS = {
    // Identity
    ssn: /\b\d{3}-\d{2}-\d{4}\b/g,
    tax_id: /\b\d{2}-\d{7}\b/g,
    // Financial
    credit_card_visa: /\b4\d{3}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g,
    credit_card_mc: /\b5[1-5]\d{2}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g,
    credit_card_amex: /\b3[47]\d{2}[\s-]?\d{6}[\s-]?\d{5}\b/g,
    credit_card_discover: /\b6(?:011|5\d{2})[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g,
    // Bank accounts — only match near context words to avoid false positives
    bank_account: /(?:routing|account|bank|iban|swift)[\s#:]*\b\d{8,17}\b/gi,
    // Contact
    email: /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi,
    phone_us: /\b(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b/g,
    // Date of birth — require contextual keyword to avoid matching arbitrary dates
    date_of_birth: /(?:DOB|date\s+of\s+birth|born|birthday|birth\s+date)[\s:]*\b\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}\b/gi,
    // Identity documents — require context words
    passport: /(?:passport)[\s#:]*\b[A-Z0-9]{6,9}\b/gi,
    drivers_license: /(?:license|DL|driver'?s?\s*license)[\s#:]*\b[A-Z0-9]{5,15}\b/gi,
    // Secrets & credentials
    aws_key: /\bAKIA[0-9A-Z]{16}\b/g,
    stripe_key: /\bsk_live_[0-9a-zA-Z]{24,}\b/g,
    github_token: /\b(?:ghp|gho|ghu)_[0-9a-zA-Z]{36}\b/g,
    openai_key: /\bsk-[a-zA-Z0-9]{20,}\b/g,
    private_key: /-----BEGIN[A-Z\s]*PRIVATE KEY-----/g,
    // Legal markers
    legal_confidential: /\bCONFIDENTIAL\b/g,
    legal_privileged: /\bPRIVILEGED\b/g,
};
// ── Scanning ───────────────────────────────────────────────────────────
/**
 * Run all PII patterns against the given text and return matches with counts.
 * Only patterns that match at least once are included.
 */
export function scanForPII(text) {
    const matches = [];
    for (const [type, pattern] of Object.entries(PII_PATTERNS)) {
        // Reset lastIndex for global regexes so they work across repeated calls
        pattern.lastIndex = 0;
        const hits = text.match(pattern);
        if (hits && hits.length > 0) {
            matches.push({ type, count: hits.length });
        }
    }
    return matches;
}
// ── Classification ─────────────────────────────────────────────────────
/** Types that immediately trigger `restricted` classification. */
const RESTRICTED_TYPES = new Set([
    "ssn",
    "tax_id",
    "credit_card_visa",
    "credit_card_mc",
    "credit_card_amex",
    "credit_card_discover",
    "bank_account",
    "private_key",
    "aws_key",
    "stripe_key",
]);
/** Types that trigger `confidential` when combined or on their own. */
const CONFIDENTIAL_TYPES = new Set([
    "passport",
    "drivers_license",
    "date_of_birth",
]);
/** Types considered "contact" PII — confidential only when combined. */
const CONTACT_TYPES = new Set(["email", "phone_us"]);
/** Legal marker types — trigger `internal` classification. */
const LEGAL_TYPES = new Set(["legal_confidential", "legal_privileged"]);
/**
 * Derive a classification level from PII scan results.
 *
 * Hierarchy (highest wins):
 *   restricted  > confidential > internal > public
 */
export function classifyFromPII(matches) {
    if (matches.length === 0)
        return "public";
    const types = new Set(matches.map((m) => m.type));
    // Any restricted-class PII → restricted
    for (const t of types) {
        if (RESTRICTED_TYPES.has(t))
            return "restricted";
    }
    // Confidential-class documents (passport, DL, DOB)
    for (const t of types) {
        if (CONFIDENTIAL_TYPES.has(t))
            return "confidential";
    }
    // Email + phone together → confidential
    const hasEmail = types.has("email");
    const hasPhone = types.has("phone_us");
    if (hasEmail && hasPhone)
        return "confidential";
    // Any secret/token type not already caught → restricted (safety net)
    const secretTypes = new Set(["github_token", "openai_key"]);
    for (const t of types) {
        if (secretTypes.has(t))
            return "restricted";
    }
    // Single contact PII or legal markers → internal
    for (const t of types) {
        if (CONTACT_TYPES.has(t) || LEGAL_TYPES.has(t))
            return "internal";
    }
    // Fallback — something matched but doesn't fit above categories
    return "internal";
}
//# sourceMappingURL=pii-patterns.js.map