/**
 * pii-check.js — Scans project source files for personal information before pushing.
 *
 * Usage:  node scripts/pii-check.js
 * Exit 0 = clean, Exit 1 = PII found.
 */

import { execSync } from "child_process";
import { readFileSync } from "fs";
import { resolve, extname } from "path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Paths / globs to skip entirely. */
const EXCLUDED_PREFIXES = ["node_modules/", ".git/", "data/", "logs/", "certs/", "test/", "scripts/"];
const EXCLUDED_FILES = ["package-lock.json"];
const EXCLUDED_EXTENSIONS = [".db"];

/** Binary extensions we never want to scan. */
const BINARY_EXTENSIONS = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".ico", ".bmp", ".webp", ".svg",
  ".woff", ".woff2", ".ttf", ".eot", ".otf",
  ".zip", ".gz", ".tar", ".7z", ".rar",
  ".exe", ".dll", ".so", ".dylib",
  ".pdf", ".doc", ".docx", ".xls", ".xlsx",
  ".mp3", ".mp4", ".wav", ".avi", ".mov",
  ".db", ".sqlite", ".sqlite3",
]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getTrackedFiles() {
  const raw = execSync("git ls-files", { encoding: "utf-8" });
  return raw
    .split("\n")
    .map((f) => f.trim())
    .filter(Boolean);
}

function shouldScan(filePath) {
  if (EXCLUDED_PREFIXES.some((p) => filePath.startsWith(p))) return false;
  if (EXCLUDED_FILES.some((f) => filePath.endsWith(f))) return false;
  const ext = extname(filePath).toLowerCase();
  if (EXCLUDED_EXTENSIONS.includes(ext)) return false;
  if (BINARY_EXTENSIONS.has(ext)) return false;
  return true;
}

function isBinaryContent(buf) {
  // Quick heuristic: if the first 8 KB contain a NUL byte it is likely binary.
  const slice = buf.subarray(0, 8192);
  for (let i = 0; i < slice.length; i++) {
    if (slice[i] === 0) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// PII detection patterns
// ---------------------------------------------------------------------------

/**
 * Each detector receives a line of text, the 1-based line number, and the
 * relative file path. It returns an array of finding descriptions (empty = OK).
 */

// 1. Email addresses -----------------------------------------------------------
function checkEmail(line) {
  const findings = [];
  const re = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g;
  let m;
  while ((m = re.exec(line)) !== null) {
    const email = m[0];
    // Allow well-known placeholder / no-reply addresses
    if (/^noreply@/i.test(email)) continue;
    if (/^no-reply@/i.test(email)) continue;
    if (/@example\.(com|org|net)$/i.test(email)) continue;
    if (/@localhost$/i.test(email)) continue;
    if (/@test\.(com|org|net)$/i.test(email)) continue;
    if (/^user@/i.test(email)) continue;
    if (/^admin@example/i.test(email)) continue;
    if (/^(info|support|hello|contact|test)@/i.test(email)) continue;
    // Allow emails that are clearly part of a Co-Authored-By git trailer
    if (/noreply@anthropic\.com$/i.test(email)) continue;
    if (/noreply@github\.com$/i.test(email)) continue;
    findings.push(`Email address: ${email}`);
  }
  return findings;
}

// 2 & 6. Real Windows user paths -----------------------------------------------
const PLACEHOLDER_USERNAMES = new Set([
  "username", "user", "your-username", "your_username", "yourusername",
  "%username%", "<username>", "{username}", "currentuser", "default",
  "public", "all users", "administrator", "admin", "appdata",
]);

function checkWindowsPath(line) {
  const findings = [];
  // Match both slash styles:  C:\Users\name\  or  C:/Users/name/
  const re = /[Cc]:[/\\]Users[/\\]([^/\\:*?"<>|\s]+)/g;
  let m;
  while ((m = re.exec(line)) !== null) {
    const name = m[1];
    if (PLACEHOLDER_USERNAMES.has(name.toLowerCase())) continue;
    // Template / env-variable style
    if (/^[<%{$]/.test(name) || /[>%}]$/.test(name)) continue;
    findings.push(`Windows user path: ${m[0]}`);
  }
  return findings;
}

// 3. Hardcoded IP addresses ----------------------------------------------------
const SAFE_IPS = new Set(["127.0.0.1", "0.0.0.0", "255.255.255.255"]);

function checkIP(line) {
  const findings = [];
  const re = /\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/g;
  let m;
  while ((m = re.exec(line)) !== null) {
    const ip = m[1];
    if (SAFE_IPS.has(ip)) continue;
    // Allow private 192.168.x.x ranges (common in docs / examples)
    if (/^192\.168\./.test(ip)) continue;
    // Allow 10.x.x.x and 172.16-31.x.x private ranges (common in configs)
    if (/^10\./.test(ip)) continue;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) continue;
    // Allow link-local 169.254.x.x
    if (/^169\.254\./.test(ip)) continue;
    // Skip version-number-looking things (e.g. "version 1.2.3.4")
    // Require all octets to be 0-255
    const octets = ip.split(".").map(Number);
    if (octets.some((o) => o > 255)) continue;
    findings.push(`Hardcoded IP address: ${ip}`);
  }
  return findings;
}

// 4. Phone numbers -------------------------------------------------------------
function checkPhone(line) {
  const findings = [];
  const patterns = [
    /\+\d{1,3}[-.\s]?\(?\d{2,4}\)?[-.\s]?\d{3,4}[-.\s]?\d{3,4}\b/g,
    /\(\d{3}\)\s?\d{3}[-.]?\d{4}\b/g,
  ];
  for (const re of patterns) {
    let m;
    while ((m = re.exec(line)) !== null) {
      const phone = m[0].trim();
      // Skip if it looks like a version string or timestamp
      if (/^\+0+$/.test(phone.replace(/\D/g, ""))) continue;
      findings.push(`Phone number: ${phone}`);
    }
  }
  return findings;
}

// 5. Hardcoded secrets / API keys ----------------------------------------------
const KNOWN_KEY_PREFIXES = ["sk-", "pk-", "ghp_", "gho_", "ghs_", "ghr_",
  "xoxb-", "xoxp-", "xoxa-", "xoxr-", "AKIA", "sk_live_", "pk_live_",
  "sk_test_", "pk_test_", "eyJ", "glpat-", "npm_", "pypi-"];

const SAFE_SECRET_PLACEHOLDERS = new Set([
  "change-me-generate-a-real-secret",
  "change-me",
  "changeme",
  "your-api-key",
  "your_api_key",
  "yourapikey",
  "replace-me",
  "replaceme",
  "xxx",
  "todo",
]);

function checkSecrets(line) {
  const findings = [];

  // Check for known API key prefixes followed by substantial content
  for (const prefix of KNOWN_KEY_PREFIXES) {
    const idx = line.indexOf(prefix);
    if (idx === -1) continue;
    // Grab the token that starts with the prefix
    const rest = line.slice(idx);
    const tokenMatch = rest.match(/^[A-Za-z0-9_\-+/=.]+/);
    if (!tokenMatch) continue;
    const token = tokenMatch[0];
    if (token.length >= 20) {
      // Check it is not a placeholder
      if (SAFE_SECRET_PLACEHOLDERS.has(token.toLowerCase())) continue;
      const display = token.length > 24 ? token.slice(0, 24) + "..." : token;
      findings.push(`Possible hardcoded secret: ${display}`);
    }
  }

  // Generic long hex/base64 strings assigned as values (32+ chars)
  const genericRe = /["'`]([A-Za-z0-9+/=_\-]{32,})["'`]/g;
  let m;
  while ((m = genericRe.exec(line)) !== null) {
    const val = m[1];
    if (SAFE_SECRET_PLACEHOLDERS.has(val.toLowerCase())) continue;
    if (val === "CHANGE-ME-generate-a-real-secret") continue;
    if (val === "CHANGE-ME-generate-an-admin-secret") continue;
    // Skip things that are obviously hashes in package-lock, or common base64 test data
    // Only flag if it has mixed case or digits (looks key-like, not a word)
    const hasDigit = /\d/.test(val);
    const hasMixed = /[a-z]/.test(val) && /[A-Z]/.test(val);
    if (hasDigit || hasMixed) {
      // Avoid flagging if already caught by prefix check
      if (KNOWN_KEY_PREFIXES.some((p) => val.startsWith(p))) continue;
      const display = val.length > 24 ? val.slice(0, 24) + "..." : val;
      findings.push(`Possible hardcoded secret: ${display}`);
    }
  }

  return findings;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const files = getTrackedFiles().filter(shouldScan);
  const issues = [];
  let scanned = 0;

  for (const relPath of files) {
    const absPath = resolve(relPath);
    let buf;
    try {
      buf = readFileSync(absPath);
    } catch {
      // File might have been deleted but still tracked — skip.
      continue;
    }

    if (isBinaryContent(buf)) continue;

    scanned++;
    const content = buf.toString("utf-8");
    const lines = content.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const lineNo = i + 1;

      const detectors = [
        checkEmail,
        checkWindowsPath,
        checkIP,
        checkPhone,
        checkSecrets,
      ];

      for (const detect of detectors) {
        const findings = detect(line);
        for (const desc of findings) {
          issues.push({ file: relPath, line: lineNo, desc });
        }
      }
    }
  }

  // De-duplicate identical findings (same file + line + description)
  const seen = new Set();
  const unique = issues.filter((iss) => {
    const key = `${iss.file}:${iss.line}:${iss.desc}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  // Output
  console.log("PII Check Results");
  console.log("=================");
  console.log();

  if (unique.length === 0) {
    console.log(`OK: No personal information found in ${scanned} files scanned.`);
    process.exit(0);
  } else {
    for (const iss of unique) {
      console.log(`FAIL: ${iss.file}:${iss.line} \u2014 ${iss.desc}`);
    }
    console.log();
    console.log(
      `${unique.length} issue${unique.length === 1 ? "" : "s"} found. Fix before pushing.`
    );
    process.exit(1);
  }
}

main();
