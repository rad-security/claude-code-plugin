/**
 * clawkeeper_log_action handler
 *
 * Pure structured audit logging. Records each major task step with an
 * action description, involved files (hashed), and classification level.
 * Always logs locally; also reports to the API when connected.
 */
import type { CoworkReporter } from "../reporter.js";
import type { CoworkConfig } from "../config.js";
export interface LogActionResult {
    logged: boolean;
    event_id: string;
}
export declare function logAction(action: string, files: string[] | undefined, classification: string | undefined, reporter: CoworkReporter, config: CoworkConfig): LogActionResult;
