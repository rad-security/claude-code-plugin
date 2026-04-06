/**
 * clawkeeper_check_sensitivity handler
 *
 * Classifies a file's sensitivity before Cowork reads, writes, deletes, or
 * shares it. Returns the classification level, any PII types found, the
 * policy verdict, and human-readable guidance for Claude.
 */
import { PolicyEngine } from "../detection/policy-engine.js";
import type { CoworkReporter } from "../reporter.js";
import type { CoworkConfig } from "../config.js";
export interface CheckSensitivityResult {
    classification: "public" | "internal" | "confidential" | "restricted";
    contains: string[];
    policy_result: "allowed" | "warn" | "denied";
    guidance: string;
}
export declare function checkSensitivity(filePath: string, operation: string, policy: PolicyEngine, reporter: CoworkReporter, config: CoworkConfig): CheckSensitivityResult;
