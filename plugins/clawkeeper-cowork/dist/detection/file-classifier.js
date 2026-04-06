/**
 * File classifier for the Cowork connector.
 *
 * Classifies files by extension and, for text-readable files under 100 KB,
 * scans the first 10 KB of content for PII to potentially bump the
 * classification level.
 */
import * as fs from "node:fs";
import { homedir } from "node:os";
import * as path from "node:path";
import { scanForPII, classifyFromPII } from "./pii-patterns.js";
// ── Extension maps ─────────────────────────────────────────────────────
/** Base classification derived purely from file extension. */
const EXTENSION_CLASSIFICATION = {
    // Crypto / key material → restricted
    ".pem": "restricted",
    ".key": "restricted",
    ".pfx": "restricted",
    ".p12": "restricted",
    ".jks": "restricted",
    // Environment files → restricted
    ".env": "restricted",
    // Spreadsheets & documents → internal
    ".xlsx": "internal",
    ".xls": "internal",
    ".csv": "internal",
    ".tsv": "internal",
    ".pdf": "internal",
    ".docx": "internal",
    ".doc": "internal",
    ".pptx": "internal",
};
/** Extensions whose content can be read as UTF-8 text for PII scanning. */
const TEXT_READABLE = new Set([
    ".txt",
    ".csv",
    ".tsv",
    ".md",
    ".json",
    ".xml",
    ".yaml",
    ".yml",
    ".log",
    ".html",
    ".htm",
    ".sql",
]);
/** Maximum file size (in bytes) to attempt content scanning. */
const MAX_FILE_SIZE = 100 * 1024; // 100 KB
/** How much of the file to read for PII scanning. */
const SCAN_BYTES = 10 * 1024; // 10 KB
// ── Classification rank (for "bump up" logic) ──────────────────────────
const RANK = {
    public: 0,
    internal: 1,
    confidential: 2,
    restricted: 3,
};
function higherClassification(a, b) {
    return (RANK[a] ?? 0) >= (RANK[b] ?? 0) ? a : b;
}
// ── Helpers ────────────────────────────────────────────────────────────
/**
 * Resolve extension-based classification. Handles `.env.*` variants
 * (e.g. `.env.local`, `.env.production`) by checking the basename.
 */
function classifyByExtension(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    const basename = path.basename(filePath).toLowerCase();
    // .env and .env.* files → restricted
    if (basename === ".env" || basename.startsWith(".env.")) {
        return "restricted";
    }
    return EXTENSION_CLASSIFICATION[ext] ?? "public";
}
// ── Public API ─────────────────────────────────────────────────────────
/**
 * Classify a file synchronously.
 *
 * 1. Start with extension-based classification.
 * 2. If the file is text-readable and under 100 KB, read the first 10 KB
 *    and scan for PII.
 * 3. If PII is found, bump the classification upward if the PII-derived
 *    level is higher than the extension-based level.
 */
export function classifyFile(filePath) {
    // Expand ~ to home directory
    const resolvedPath = filePath.startsWith("~/")
        ? path.join(homedir(), filePath.slice(1))
        : filePath.startsWith("~")
            ? path.join(homedir(), filePath.slice(1))
            : filePath;
    const baseClassification = classifyByExtension(filePath);
    const ext = path.extname(filePath).toLowerCase();
    const detectedTypes = [];
    let scannedContent = false;
    // Determine if we should attempt content scanning
    if (!TEXT_READABLE.has(ext)) {
        return { classification: baseClassification, contains: detectedTypes, detectedTypes, scannedContent };
    }
    // Stat the file — if it doesn't exist or is too large, skip scanning
    let stat;
    try {
        stat = fs.statSync(resolvedPath);
    }
    catch {
        return { classification: baseClassification, contains: detectedTypes, detectedTypes, scannedContent };
    }
    if (!stat.isFile() || stat.size > MAX_FILE_SIZE) {
        return { classification: baseClassification, contains: detectedTypes, detectedTypes, scannedContent };
    }
    // Read the first SCAN_BYTES of the file
    let content;
    try {
        const fd = fs.openSync(resolvedPath, "r");
        const buffer = Buffer.alloc(Math.min(SCAN_BYTES, stat.size));
        fs.readSync(fd, buffer, 0, buffer.length, 0);
        fs.closeSync(fd);
        content = buffer.toString("utf-8");
    }
    catch {
        return { classification: baseClassification, contains: detectedTypes, detectedTypes, scannedContent };
    }
    scannedContent = true;
    // Run PII detection on the content
    const piiMatches = scanForPII(content);
    if (piiMatches.length === 0) {
        return { classification: baseClassification, contains: detectedTypes, detectedTypes, scannedContent };
    }
    // Collect detected PII type names
    for (const m of piiMatches) {
        detectedTypes.push(m.type);
    }
    // Derive classification from PII and bump if higher
    const piiClassification = classifyFromPII(piiMatches);
    const finalClassification = higherClassification(baseClassification, piiClassification);
    return {
        classification: finalClassification,
        contains: detectedTypes,
        detectedTypes,
        scannedContent,
    };
}
//# sourceMappingURL=file-classifier.js.map