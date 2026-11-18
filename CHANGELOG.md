# Changelog

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
