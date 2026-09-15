/**
 * Deterministic post-transcription corrections driven by the custom dictionary.
 *
 * The dictionary only biases STT decoding (prompt / keyterms) and the cleanup
 * LLM; nothing guaranteed its exact spelling survived. This module closes that
 * gap with two conservative, dictionary-driven rules applied to the final
 * transcript:
 *
 * 1. Detokenize — separator-bearing entries ("origin/main", "e-mail") are
 *    matched against the spoken-apart forms Whisper actually emits
 *    ("origin main", "origin / main", "email") and rewritten to the entry.
 * 2. Fuzzy — a token within edit distance 1 of a dictionary word (a
 *    misheard name like "Shinade" for "Sinead") is corrected to the entry.
 *
 * Both rules are case-insensitive, boundary-safe, and skip tokens that are
 * already dictionary words, snippet triggers, or everyday words, so a wrong
 * replacement requires the transcript to sit one edit away from a dictionary
 * entry while not being a common word — rare enough to be worth fixing.
 */

export interface DictionaryCorrection {
  /** Matched text, as it appeared in the transcript. */
  original: string;
  /** Dictionary entry it was rewritten to. */
  replacement: string;
  start: number;
  end: number;
  rule: "detokenize" | "fuzzy";
}

export interface DictionaryCorrectionResult {
  text: string;
  corrections: DictionaryCorrection[];
}

export interface CorrectDictionaryMatchesOptions {
  /**
   * Lowercased words the caller rewrites elsewhere (snippet triggers).
   * Fuzzy correction must not mutate them before expansion runs.
   */
  skipWords?: Iterable<string>;
}

// Fuzzy correction on shorter tokens is too collision-prone ("main"/"rain"):
// a single edit turns one real word into another far more often than a
// mishearing into a dictionary word.
const MIN_FUZZY_TOKEN_LENGTH = 5;
const MIN_FUZZY_ENTRY_LENGTH = 4;
const MAX_EDIT_DISTANCE = 1;

// Everyday words are excluded from fuzzy correction: swapping two common words
// at distance 1 ("there"→"three", "want"→"wanting" aside) is a content edit we
// must never make. Superset of the usual function words so the list also covers
// tokens long enough to reach the fuzzy rule.
const COMMON_WORDS = new Set(
  `about above across after again against almost alone along already also although
  always among another any because been before being below between both build built
  can cannot come could did does doing done down during each early else enough even
  ever every first five for found four from front full further gave gets give given
  goes going gone good got great had has have having help here hers high him his
  hold home hope hour into item its itself just keep kept kind know known last later
  least leave left less let like line list little live local long look lot made make
  many maybe mean means meet might more most move much must name near need never
  next nine none noted now null number object once ones only open order other ought
  out over own part past per place plan please point put quite read real really
  reason right room said same say says see seem seen sees several shall she should
  show side since some soon still such sure take taken tell ten than that their
  theirs them then there these they thing think this those though three through
  thus time times today together told too took total toward turn two under until
  upon used uses using usually very want wants was way well went were what when
  where whether which while who whole whom whose why will with within without
  word works would year years yes yet you your`.split(/\s+/)
);

const TOKEN_PATTERN = /[\p{L}\p{N}]+(?:['’_-][\p{L}\p{N}]+)*/gu;
// Entries eligible for fuzzy matching: plain words (optionally hyphenated or
// possessive). Separator-bearing entries go through detokenize instead.
const FUZZY_ENTRY_PATTERN = /^[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*$/u;

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Optimal-string-alignment Damerau-Levenshtein distance (adjacent transpositions). */
export function damerauDistance(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  if (a === b) return 0;

  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array<number>(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;

  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        dp[i][j] = Math.min(dp[i][j], dp[i - 2][j - 2] + 1);
      }
    }
  }
  return dp[m][n];
}

interface DetokenizeEntry {
  entry: string;
  regex: RegExp;
}

/**
 * Builds a per-entry matcher for separator-bearing entries. Each punctuation
 * gap becomes `\s*(?:<sep>)?\s*`, so "origin/main" matches "origin main",
 * "origin / main", and "originmain" alike while "origin/main" itself matches
 * back unchanged (and is skipped as a no-op).
 */
function buildDetokenizeEntries(dictionary: string[]): DetokenizeEntry[] {
  const entries: DetokenizeEntry[] = [];
  for (const raw of dictionary) {
    const entry = typeof raw === "string" ? raw.trim() : "";
    if (!entry || !/\p{P}|\p{S}/u.test(entry)) continue;
    const runs = entry.match(/[\p{L}\p{N}]+/gu);
    if (!runs || runs.length < 2) continue;
    // Split into alnum runs and the gaps between them.
    const parts: { text: string; isRun: boolean }[] = [];
    const runPattern = /[\p{L}\p{N}]+|[^\p{L}\p{N}]+/gu;
    for (const part of entry.match(runPattern) ?? []) {
      parts.push({ text: part, isRun: /[\p{L}\p{N}]/u.test(part[0]) });
    }
    const pattern = parts
      .map(({ text, isRun }) =>
        isRun ? escapeRegExp(text) : `\\s*(?:${escapeRegExp(text.trim())})?\\s*`
      )
      .join("");
    entries.push({
      entry,
      regex: new RegExp(`(?<=^|[\\s\\p{P}\\p{S}])(?:${pattern})(?=$|[\\s\\p{P}\\p{S}])`, "giu"),
    });
  }
  return entries;
}

/** Applies the dictionary casing to the matched token's capitalization style. */
function matchCasing(token: string, entry: string): string {
  if (token.length > 1 && token === token.toUpperCase() && /\p{L}/u.test(token)) {
    return entry.toUpperCase();
  }
  if (token[0] === token[0].toUpperCase() && token[0] !== token[0].toLowerCase()) {
    return entry.charAt(0).toUpperCase() + entry.slice(1);
  }
  return entry;
}

interface MatchRange {
  start: number;
  end: number;
  original: string;
  replacement: string;
  rule: DictionaryCorrection["rule"];
}

function collectDetokenizeMatches(text: string, entries: DetokenizeEntry[]): MatchRange[] {
  const matches: MatchRange[] = [];
  for (const { entry, regex } of entries) {
    for (const match of text.matchAll(regex)) {
      const matched = match[0];
      // Already spelled exactly like the entry — nothing to fix.
      if (matched.toLowerCase() === entry.toLowerCase()) continue;
      matches.push({
        start: match.index,
        end: match.index + matched.length,
        original: matched,
        replacement: entry,
        rule: "detokenize",
      });
    }
  }
  return matches;
}

function collectFuzzyMatches(
  text: string,
  fuzzyEntries: string[],
  exactWords: Set<string>,
  skipWords: Set<string>
): MatchRange[] {
  const matches: MatchRange[] = [];
  for (const match of text.matchAll(TOKEN_PATTERN)) {
    const token = match[0];
    if (token.length < MIN_FUZZY_TOKEN_LENGTH) continue;
    const normalized = token.toLowerCase();
    if (exactWords.has(normalized) || skipWords.has(normalized) || COMMON_WORDS.has(normalized)) {
      continue;
    }
    let best: { entry: string; distance: number } | null = null;
    for (const entry of fuzzyEntries) {
      if (Math.abs(entry.length - token.length) > MAX_EDIT_DISTANCE) continue;
      const distance = damerauDistance(normalized, entry.toLowerCase());
      if (distance > MAX_EDIT_DISTANCE) continue;
      if (
        !best ||
        distance < best.distance ||
        (distance === best.distance && entry.length > best.entry.length)
      ) {
        best = { entry, distance };
      }
    }
    if (!best) continue;
    matches.push({
      start: match.index,
      end: match.index + token.length,
      original: token,
      replacement: matchCasing(token, best.entry),
      rule: "fuzzy",
    });
  }
  return matches;
}

function resolveOverlaps(matches: MatchRange[]): MatchRange[] {
  const rulePriority: Record<DictionaryCorrection["rule"], number> = {
    detokenize: 0,
    fuzzy: 1,
  };
  const sorted = [...matches].sort(
    (a, b) => a.start - b.start || b.end - a.end || rulePriority[a.rule] - rulePriority[b.rule]
  );
  const kept: MatchRange[] = [];
  let lastEnd = -1;
  for (const match of sorted) {
    if (match.start < lastEnd) continue;
    kept.push(match);
    lastEnd = match.end;
  }
  return kept;
}

/**
 * Corrects the transcript toward the custom dictionary. Returns the rewritten
 * text plus the corrections applied, so callers can log or surface them.
 * Pure: no store access, safe to call per dictation.
 */
export function correctDictionaryMatches(
  text: string,
  dictionary?: string[] | null,
  options?: CorrectDictionaryMatchesOptions
): DictionaryCorrectionResult {
  if (!text || !Array.isArray(dictionary) || dictionary.length === 0) {
    return { text, corrections: [] };
  }

  const entries = dictionary
    .map((word) => (typeof word === "string" ? word.trim() : ""))
    .filter((word) => word.length > 0);
  if (entries.length === 0) {
    return { text, corrections: [] };
  }

  const exactWords = new Set(entries.map((entry) => entry.toLowerCase()));
  const skipWords = new Set([...(options?.skipWords ?? [])].map((word) => word.toLowerCase()));

  const matches = [
    ...collectDetokenizeMatches(text, buildDetokenizeEntries(entries)),
    ...collectFuzzyMatches(
      text,
      entries.filter((entry) => FUZZY_ENTRY_PATTERN.test(entry)),
      exactWords,
      skipWords
    ),
  ];
  if (matches.length === 0) {
    return { text, corrections: [] };
  }

  const kept = resolveOverlaps(matches);
  if (kept.length === 0) {
    return { text, corrections: [] };
  }

  let result = "";
  let cursor = 0;
  for (const match of kept) {
    result += text.slice(cursor, match.start) + match.replacement;
    cursor = match.end;
  }
  result += text.slice(cursor);

  return {
    text: result,
    corrections: kept.map(({ original, replacement, start, end, rule }) => ({
      original,
      replacement,
      start,
      end,
      rule,
    })),
  };
}
