/**
 * clawkeeper_verify_recipient handler
 *
 * Verifies whether an external recipient (email/domain) is allowed
 * before Cowork sends data. Checks against the org's allowed domain
 * list and considers the classification of the data being sent.
 */
import { PolicyEngine } from "../detection/policy-engine.js";
import type { CoworkReporter } from "../reporter.js";
import type { CoworkConfig } from "../config.js";
export interface VerifyRecipientResult {
    allowed: boolean;
    domain: string;
    policy_note: string;
}
export declare function verifyRecipient(recipient: string, dataClassification: string | undefined, policy: PolicyEngine, reporter: CoworkReporter, config: CoworkConfig): VerifyRecipientResult;
