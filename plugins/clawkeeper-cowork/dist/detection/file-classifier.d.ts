/**
 * File classifier for the Cowork connector.
 *
 * Classifies files by extension and, for text-readable files under 100 KB,
 * scans the first 10 KB of content for PII to potentially bump the
 * classification level.
 */
export type ClassificationLevel = "restricted" | "confidential" | "internal" | "public";
export interface FileClassification {
    /** The computed classification level. */
    classification: ClassificationLevel;
    /** List of PII types or signals detected in the file. */
    contains: string[];
    /** Alias for `contains` — used by tool handlers. */
    detectedTypes: string[];
    /** Whether file content was actually read and scanned. */
    scannedContent: boolean;
}
/**
 * Classify a file synchronously.
 *
 * 1. Start with extension-based classification.
 * 2. If the file is text-readable and under 100 KB, read the first 10 KB
 *    and scan for PII.
 * 3. If PII is found, bump the classification upward if the PII-derived
 *    level is higher than the extension-based level.
 */
export declare function classifyFile(filePath: string): FileClassification;
