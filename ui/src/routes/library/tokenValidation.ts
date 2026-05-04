// ui/src/routes/library/tokenValidation.ts

export interface ValidationResult {
  valid: boolean;
  tokens: string[];
  error?: string;
}

// Splits whitespace-delimited tokens from input. The popover requires
// exactly one token (1->1 fixes only). Find/replace allows any N as long as
// search and replacement match counts.
export function tokenize(value: string): string[] {
  const trimmed = value.trim();
  if (trimmed === "") return [];
  return trimmed.split(/\s+/);
}

export function validateSingleToken(value: string): ValidationResult {
  const tokens = tokenize(value);
  if (tokens.length === 1) return { valid: true, tokens };
  return {
    valid: false,
    tokens,
    error: tokens.length === 0
      ? "Replacement cannot be empty."
      : "Use a single token. To represent a multi-word term without splitting timing, squash it (e.g. SanJose).",
  };
}

export function validateMatchedCount(search: string, replacement: string): ValidationResult {
  const oldTokens = tokenize(search);
  const newTokens = tokenize(replacement);
  if (oldTokens.length === 0) {
    return { valid: false, tokens: [], error: "Search cannot be empty." };
  }
  if (newTokens.length === 0) {
    return { valid: false, tokens: [], error: "Replacement cannot be empty." };
  }
  if (oldTokens.length !== newTokens.length) {
    return {
      valid: false,
      tokens: newTokens,
      error: "Token count must match. Splitting or merging would corrupt timing — use a squashed form (e.g. SanJose) if needed.",
    };
  }
  return { valid: true, tokens: newTokens };
}
