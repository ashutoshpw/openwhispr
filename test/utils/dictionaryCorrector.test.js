const test = require("node:test");
const assert = require("node:assert/strict");

const {
  correctDictionaryMatches,
  damerauDistance,
} = require("../../src/utils/dictionaryCorrector.ts");

test("detokenize: spoken-apart separator entry is rewritten", () => {
  const result = correctDictionaryMatches("pushed to origin main today", ["origin/main"]);
  assert.equal(result.text, "pushed to origin/main today");
  assert.deepEqual(result.corrections, [
    { original: "origin main", replacement: "origin/main", start: 10, end: 21, rule: "detokenize" },
  ]);
});

test("detokenize: spaced separator is rewritten", () => {
  assert.equal(
    correctDictionaryMatches("diff origin / main against it", ["origin/main"]).text,
    "diff origin/main against it"
  );
});

test("detokenize: case-insensitive match uses entry casing", () => {
  assert.equal(
    correctDictionaryMatches("see Origin Main branch", ["origin/main"]).text,
    "see origin/main branch"
  );
});

test("detokenize: exact entry spelling is a no-op", () => {
  assert.deepEqual(correctDictionaryMatches("compare with origin/main now", ["origin/main"]), {
    text: "compare with origin/main now",
    corrections: [],
  });
});

test("detokenize: respects word boundaries", () => {
  assert.equal(
    correctDictionaryMatches("the origin mainframe broke", ["origin/main"]).text,
    "the origin mainframe broke"
  );
});

test("detokenize: hyphenated entry matches fused and spaced forms", () => {
  assert.equal(correctDictionaryMatches("email me the e mail", ["e-mail"]).text, "e-mail me the e-mail");
});

test("detokenize: dotted entry matches fused and spaced forms", () => {
  assert.equal(
    correctDictionaryMatches("check fig 3 in fig3 doc", ["fig.3"]).text,
    "check fig.3 in fig.3 doc"
  );
});

test("detokenize: underscore entry matches spaced form", () => {
  assert.equal(correctDictionaryMatches("run snake case names", ["snake_case"]).text, "run snake_case names");
});

test("fuzzy: one substitution is corrected", () => {
  assert.equal(
    correctDictionaryMatches("deploying to kubernates now", ["Kubernetes"]).text,
    "deploying to Kubernetes now"
  );
});

test("fuzzy: one insertion is corrected", () => {
  assert.equal(correctDictionaryMatches("connected to postgressql", ["PostgreSQL"]).text, "connected to PostgreSQL");
});

test("fuzzy: all-caps token keeps its casing style", () => {
  assert.equal(correctDictionaryMatches("KUBERNATES cluster", ["kubernetes"]).text, "KUBERNETES cluster");
});

test("fuzzy: capitalized token gets a capitalized replacement", () => {
  assert.equal(correctDictionaryMatches("ping Kubernates", ["kubernetes"]).text, "ping Kubernetes");
});

test("fuzzy: exact match (any case) is never rewritten", () => {
  assert.equal(correctDictionaryMatches("meet Sinead tomorrow", ["sinead"]).text, "meet Sinead tomorrow");
});

test("fuzzy: common words are never corrected", () => {
  assert.equal(correctDictionaryMatches("I would go there now", ["three"]).text, "I would go there now");
});

test("fuzzy: tokens under five characters are never corrected", () => {
  assert.equal(correctDictionaryMatches("a main rain of thought", ["main"]).text, "a main rain of thought");
});

test("fuzzy: already-correct and distant tokens are untouched", () => {
  assert.equal(correctDictionaryMatches("mainframe and mains", ["mains"]).text, "mainframe and mains");
});

test("fuzzy: tokens beyond edit distance one are untouched", () => {
  assert.equal(correctDictionaryMatches("two edits apart here", ["headphones"]).text, "two edits apart here");
});

test("fuzzy: snippet triggers (skipWords) are never corrected", () => {
  const result = correctDictionaryMatches("open openwhispr now", ["openwhisper"], {
    skipWords: ["openwhispr"],
  });
  assert.equal(result.text, "open openwhispr now");
  assert.equal(correctDictionaryMatches("open openwhispr now", ["openwhisper"]).text, "open openwhisper now");
});

test("fuzzy: multiple tokens are corrected in one pass", () => {
  assert.equal(
    correctDictionaryMatches("fix postgreqsl and postgressql", ["postgresql"]).text,
    "fix postgresql and postgresql"
  );
});

test("precedence: detokenize owns the range, exact-word fuzzy adds nothing", () => {
  assert.deepEqual(correctDictionaryMatches("origin main", ["origin/main", "origin"]), {
    text: "origin/main",
    corrections: [
      { original: "origin main", replacement: "origin/main", start: 0, end: 11, rule: "detokenize" },
    ],
  });
});

test("edge cases: empty dictionary, empty text, no matches", () => {
  assert.deepEqual(correctDictionaryMatches("hello world", []), { text: "hello world", corrections: [] });
  assert.deepEqual(correctDictionaryMatches("", ["origin/main"]), { text: "", corrections: [] });
  assert.deepEqual(correctDictionaryMatches("hello", ["origin/main"]), { text: "hello", corrections: [] });
});

test("damerauDistance", () => {
  assert.equal(damerauDistance("kubernates", "kubernetes"), 1, "substitution");
  assert.equal(damerauDistance("postgressql", "postgresql"), 1, "insertion");
  assert.equal(damerauDistance("sinead", "sinad"), 1, "deletion");
  assert.equal(damerauDistance("tehre", "there"), 1, "transposition");
  assert.equal(damerauDistance("kubernetes", "docker"), 9, "far apart");
  assert.equal(damerauDistance("abc", "abcx"), 1, "one edit length diff");
});
