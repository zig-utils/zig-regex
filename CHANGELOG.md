# Changelog

## v0.5.2 - 2026-11-24

- perf(regex): keep isMatch's search DFA warm between calls (0d4b9b5)
- feat(bench): benchmark every CRS @rx pattern against PCRE2 (aa6543d)
- docs(bench): record the CRS results (523c2c6)

### Changes (v0.5.2)

- `Regex.isMatch` keeps its lazy search DFA between calls instead of building
  it from scratch every time (#56). Each `Regex` holds up to four warm DFAs,
  claimed and returned atomically, so a shared `Regex` is still safe to use
  from several threads, and a moved `Regex` keeps working. A DFA larger than
  256 states after a call is freed rather than kept. On OWASP CRS 4.28.0's 318
  `@rx` patterns, span-only `isMatch` over 24 request values went from 362.7 ms
  to 0.99 ms, against 8.59 ms for the PCRE2 interpreter and 0.56 ms with JIT,
  with identical results. The first calls, while DFAs are built, still cost
  160 to 260 ms over all patterns.
- `isMatch` on a pattern with lazy quantifiers now uses the search DFA: laziness
  changes which match is reported, never whether one exists. `find` is
  unchanged.
- Adding a lazy DFA state is all or nothing when memory runs out. Before, a
  failed allocation could free a state's key twice or leave the tables out of
  step, and a failed DFA construction leaked its buffers.
- `benchmarks/crs/compare.sh <crs-checkout>` measures every `@rx` pattern of a
  CRS checkout against PCRE2 and fails on any disagreement
  (docs/BENCHMARKS.md).

## v0.5.1 - 2026-11-23

- fix(backtrack): search on a per-call copy of the engine (#54) (a97e44a)
- perf(backtrack): store subtree facts on each node instead of re-walking (#55) (b5df4c1)

### Changes (v0.5.1)

- A `Regex` on the backtracking engine is safe to search from several threads
  at once. Each search runs on its own copy of the engine's match state
  instead of writing into the shared `Regex`; before, concurrent searches
  raced and returned wrong matches (#54). `(?i)`, lazy quantifiers, repeated
  groups and lookarounds all select this engine.
- The stored engine's `step_count` no longer changes when you search. Read a
  search's step count with the new `Regex.searchSteps(input)`.
- The backtracker computes what each subtree contains once, at compile time,
  instead of walking the subtree every time it asks while matching (#53). The
  full OWASP CRS rule set through zig-waf: a 1 KB form POST went from 85.6 ms
  to 11.9 ms.

## v0.5.0 - 2026-11-18

- docs(bench): measure regex.bt programs against PCRE2 (ad5a5c4)
- feat(bt): add serialisable bounded-backtracking programs (fed0c83)
- feat(regex): support atomic groups (?>...) (71ccdcd)

### Highlights (v0.5.0)

The constructs a linear `Program` cannot run now have a home that keeps its
guarantees: `regex.bt`, a bounded-backtracking program that is serialisable,
loads in place without allocating, matches with a fixed-size scratch and no
recursion, and stops at a per-search step budget. Atomic groups parse and
run everywhere. Numbers and the PCRE2 differential are in
docs/BENCHMARKS.md.

### New APIs

- `regex.bt`: `bt.Program` (`compile`, `bytes`, `load`, `dupe`,
  `capacity`, `isMatch`, `find`, `findFrom`, `iterator`, `findAll`, `count`),
  `bt.Scratch` (`init`, `initCapacity`, `initBuffer`, `bytesNeeded`,
  `step_budget`, `steps`), `bt.Capacity` (`slots`, `counters`, `frames`),
  `bt.MatchError` (`ScratchTooSmall`, `BudgetExceeded`, `StackExhausted`),
  `bt.magic` and `bt.format_version`. Byte mode: backreferences (numbered,
  `\k<name>`, `(?P=name)`), lookahead, bounded lookbehind, atomic groups,
  counted repeats with a counter instead of copies (`x{50000,}` is a few
  instructions) and inline modifiers, with PCRE's leftmost-first matching
  and its empty-iteration rule.
- Atomic groups `(?>...)` parse (they were a syntax error). `Regex` runs them
  on its backtracker; `Regex` and `Program` run one whose body always matches
  a single length as a plain group.
- `MODE=bt benchmarks/pcre2/diff.sh` and `zig build test-bt`.

## v0.4.1 - 2026-11-18

- feat(program): compile inline modifiers into byte-mode programs (4065d58)
- fix(parser): read {,n} as {0,n} and parse (?P=name) outside ECMAScript (31c6e85)

### Changes (v0.4.1)

From zav's E13 differential of ClamAV PCRE subsignatures and YARA regex
strings against PCRE2 (#51):

- `{,n}` is `{0,n}` outside ECMAScript, as in YARA, Perl 5.34 and PCRE2
  10.43 and later; ECMAScript keeps it literal (Annex B) and `{,}` is literal
  everywhere. Before, every pattern was read the ECMAScript way.
- `(?P=name)` parses as a named backreference (it was a syntax error), and
  `(?P<name>...)` enables `\k<name>` as `(?<name>...)` does.
- A standalone `(?flags)` lasts to the end of its group, later alternatives
  included (`(a(?i)b|c)` matches `C`), as in PCRE2 and Perl; it used to end at
  the next `|`.
- Byte-mode `Program.compile` builds inline modifiers (`(?i)`, `(?s:..)`,
  `(?-i:..)`, `(?m:..)`) into the program instead of refusing them with
  `error.UnsupportedByProgram`.

## v0.4.0 - 2026-11-18

- docs(bench): measure programs against PCRE2 after leftmost-first and prefilters (7091a3f)
- feat(program): add leftmost-first programs, reverse start search and prefilters (56d39f1)
- perf(compiler): nest the optional copies of capture-free bounded repeats (b1d4b85)
- fix(regex): end literal-alternation fast-path matches leftmost-longest (b82ec26)
- fix(bench): time basic and prefix benchmarks on the std.Io clock (1797d27)
- fix(parser): walk flat patterns along their spine in post-parse checks (f8c1ad3)

### Highlights (v0.4.0)

Programs gain PCRE2's match semantics and stop rescanning: a leftmost-first
match kind, a reverse DFA that finds match starts in linear time, and a start
prefilter that also works for patterns with assertions. Measured numbers
against PCRE2 are in docs/BENCHMARKS.md.

### New APIs

- `program.MatchKind` (`.leftmost_longest`, the default, and
  `.leftmost_first`) and `program.BuildOptions`, taken by
  `Program.compileWithOptions` and `Program.fromRegexWithOptions`.
  `Program.matchKind()` reports a program's kind; `bytes()`/`load()` keep it.
  Leftmost-first programs end matches where PCRE2, Perl and YARA do:
  alternatives in order, greedy and lazy repeats honoured.
- `vm.VM.matchAtLeftmostFirst` is public (the reference the leftmost-first
  tests use).
- `benchmarks/pcre2/diff.sh`: a differential test of leftmost-first programs
  against PCRE2; `zig build bench-basic` for the Regex micro-benchmarks.

### Behaviour changes

- The program blob layout is version 2 (`program.format_version`): it adds
  the match kind, the reversed program and the prefilter. Blobs written by
  0.3.x fail to load with `error.UnsupportedVersion`; rebuild them from their
  patterns.
- `Program.capacity().states` counts the reversed program's extra start
  state, and `Scratch.bytesNeeded` grew to `56N + 4D(C+1) + 4D(W+9) + 4H +
  16W + 40` bytes (`Scratch.boundFor`); `max_dfa_states` is now 2,088,991.
- `Regex.find`, `findAll`, `count` and the iterator end a top-level literal
  alternation leftmost-longest outside ECMAScript (`a|ab` finds `ab`), as the
  rest of `Regex` already did (#50).
- Bounded repeats of a capture-free atom compile their optional copies
  nested (`x{0,3}` as `(?:x(?:x(?:x)?)?)?`), as RE2 and Rust's regex-syntax
  do; matches are unchanged.

## v0.3.1 - 2026-11-18

- fix(program): compile repeated alternations and lazy repeats as programs (11ec9c0)

## v0.3.0 - 2026-11-18

- perf(bench): measure every literal matcher and byte-mode regex against PCRE2 (9b77709)
- fix(program): compile capture groups inside alternations as programs (f8ddb54)
- build: pin Zig 0.17.0-dev.1857 and apply its formatter (5544c99)
- feat(program): serialise programs and load them without allocation (48f6ea6)
- feat(factors): add a required-literal factor extraction API (3fa5506)
- feat(program): add a configurable DFA state cap and per-search step budget (70ec06f)
- feat(program): add flat programs and an allocation-free scratch matcher (08053cc)
- test(backtrack): keep the exact-budget test on the backtracker (95ca770)
- feat(regex): add byte-mode compilation for raw binary patterns (c4031b6)
- feat(literals): add sampled split-block Bloom prefilter (0af5bd5)
- feat(literals): add binary-safe Aho-Corasick with pattern ids (6992767)
- feat(literals): add Teddy multi-literal search (90c8649)
- fix(regex): lower case invariant Unicode sets without backtracking (684d848)
- fix(regex): recognize unconditional atomic assertion tails (c7da4fd)
- fix(regex): lower single-entry captures and nested complements (8894d44)
- fix(regex): recognize Unicode singleton separator atoms (732424d)
- fix(regex): recognize disjoint literal separator choices (8eb34df)
- fix(regex): keep literal predicates out of transition payloads (da4d2a6)
- fix(regex): execute fixed literal assertions in ordered NFA (5010174)
- fix(regex): route capture-free ordered repeats through NFA (361a0f3)
- fix(backtrack): recycle unreachable continuation states (16df987)
- fix(backtrack): search sparse lazy captures by continuation (974a077)
- fix(backtrack): retain capture-aware continuations (1117a2b)
- fix(backtrack): preserve finite repeat choice order (89d9c20)
- fix(backtrack): reconstruct final captures in fixed repeats (ab2ab7e)
- fix(backtrack): complete fixed capture-free repetitions (a341f0c)
- fix(backtrack): preserve choices inside single required repetitions (b4ff843)
- fix(backtrack): report exhausted search budgets as errors (16687e4)
- fix(parser): distinguish escaped hyphens from range separators (429fa48)
- fix(matcher): separate persistent scratch allocation (fdd9c2e)
- fix(backtrack): retain captures after a failed bounded iteration (#30) (601edb4)
- fix(ecmascript): reject quantified assertions and `(?P`, and name three more compile reasons (1d3e5c9)
- fix(ecmascript): stop refusing linear-engine patterns as ReDoS risks (30c1fa9)
- fix(ecmascript): leftmost-first captures and match ends in the VM and lazy DFA (#27) (bc14170)
- fix(ecmascript): treat CR, U+2028 and U+2029 as line terminators for multiline anchors (#28) (6e805ad)
- fix(backtrack): compare ECMAScript ignoreCase backreferences after Canonicalize (#29) (452345d)
- perf(compile): keep diagnostics off the default path (73cc22d)
- feat(parser): retain exact compile failure reasons (4783058)
- fix(compile): walk pattern spines instead of recursing over them (#23) (3e8654e)
- fix(onepass): decline non-ASCII input instead of counting bytes as characters (c60344d)
- fix(compat): avoid removed ArrayList getLast (#21) (87e9ca2)
- fix(parser): make class-set construction failure-atomic (#20) (cfb24da)
- fix(parser): roll back RegExp AST allocations on OOM (#20) (e9ea8b5)
- fix(parser): allow opening bracket class atoms (7196733)
- feat(matcher): reuse findFrom scratch (0da6eb2)
- fix(regex): keep backref repeats dynamic (2de4668)
- fix(regex): preserve quantified lookahead repeats (d0ae54e)
- fix(regex): bound unicode repeat backtracking (58907ef)
- fix(regex): consume unicode shorthand code points (489b114)
- docs: update Discord community links (3c42573)
- docs: add Community section to README (db1b9a7)

### Highlights (v0.3.0)

Byte mode, allocation-free matching and the multi-literal engines that
zig-anti-virus and zig-waf build on. Measured numbers are in
docs/BENCHMARKS.md.

### New APIs

- **Byte mode** (`CompileFlags.bytes`): the pattern and the input are raw
  bytes. `\xHH` and `\x{H..}` are single bytes, `.` matches one byte (any but
  `\n` without `dot_all`), classes are byte sets, `\s` is ASCII and case
  folding is ASCII only. Constructs defined over code points fail with the new
  `error.UnsupportedInBytesMode`.
- **Flat programs** (`regex.program`, `Program`, `Scratch`): a compiled
  pattern in one relocatable, checksummed blob, matched with a caller-sized
  `Scratch` that never allocates. `isMatch`, `find`, `findFrom`, `iterator`,
  `findAll` and `count` report spans. `Program.bytes()` serialises a program
  and `Program.load()` validates one in borrowed memory (an mmapped file)
  without allocating. `Program.compile` compiles groups as non-capturing, so
  an alternation of capture groups is still a program.
- **Search limits**: `Capacity.dfa_states` caps the lazy DFA per scratch (a
  search that outgrows it finishes on the NFA simulation), and
  `Scratch.step_budget` bounds the work of one search with
  `error.BudgetExceeded`.
- **Required-literal factors** (`regex.factors`, `requiredFactors`): literal
  strings every match must contain, for building prefilters.
- **Multi-literal engines** (`regex.literals`): `Teddy` (SIMD, up to 64
  literals), binary-safe `AhoCorasick` (dense and sparse layouts, ASCII case
  folding, pattern ids, all-matches, leftmost-longest and streaming search)
  and `Sbbf`, a sampled split-block Bloom prefilter over 4-byte grams with
  stride tiers. Each builds a relocatable blob that is searched in place and
  never allocates while searching.
- `Regex.compileWithoutCaptures`: compile with every group non-capturing.
- `Regex.compileWithFlagsDiagnostic` and `CompileErrorReason`: the exact parse
  failure reason next to the stable `RegexError`.
- `zig build bench`: the benchmark suite behind docs/BENCHMARKS.md, and
  `benchmarks/pcre2/compare.sh` for the PCRE2 comparison.

### Breaking changes

- Zig 0.17.0-dev.1857 or newer is required (`minimum_zig_version`).
- `RegexError` has a new member, `UnsupportedInBytesMode`; exhaustive
  switches over it need a prong.
- ECMAScript mode (`CompileFlags.ecmascript`) now matches leftmost-first with
  ECMAScript's repeat rules in the VM and lazy DFA, treats CR, U+2028 and
  U+2029 as multiline line terminators, and compares ignoreCase
  backreferences after Canonicalize. Match ends and captures can differ from
  0.2.x on the same pattern. It no longer refuses linear-engine patterns such
  as `/(a*)*/` as ReDoS risks.
- An exhausted backtracking search budget is reported as an error from every
  search, transform and iterator instead of as "no match".
