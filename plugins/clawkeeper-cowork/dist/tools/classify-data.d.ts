/**
 * clawkeeper_classify_data handler
 *
 * Classifies a data snippet for sensitivity before Cowork processes or
 * shares it. Detects PII patterns and legal markers, evaluates against
 * org policy, and returns classification + guidance.
 */
import { PolicyEngine } from "../detection/policy-engine.js";
import type { CoworkReporter } from "../reporter.js";
import type { CoworkConfig } from "../config.js";
export interface ClassifyDataResult {
    classification: "public" | "internal" | "confidential" | "restricted";
    detected_types: string[];
    policy_result: "allowed" | "warn" | "denied";
    guidance: string;
}
export declare function classifyData(contentPreview: string, context: string | undefined, policy: PolicyEngine, reporter: CoworkReporter, config: CoworkConfig): ClassifyDataResult;
