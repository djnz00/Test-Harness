# Expand Subtests in `prove` Output (-x/--expand[=N])

## Summary
Add a `-x, --expand[=N]` option to `prove` that expands subtests in console
output while preserving TAP parsing semantics and aggregated counts. Expansion
is formatter-only and works in both serial and parallel runs. By default
`-x` expands one level (top-level subtests); `-x N` / `--expand=N` expands up
to N levels, enabling nested subtest display.

## Key Findings (Research)
- TAP subtests are represented by an indented TAP stream with a correlated
  summary test point; the summary test point exists so consumers that do not
  parse the indented stream can still determine pass/fail. Output inside a
  subtest is indented by 4 spaces. (TAP format / tapjs docs)
- TAP parsers often recognize multiple subtest flavors (adorned `# Subtest`,
  indented, buffered, unadorned), but all share the correlated summary test
  point. This reinforces that formatter-side parsing must rely on raw lines
  rather than tokenized results. (tap-parser docs)
- Test2 distinguishes buffered subtests to avoid garbled output; subtest
  results are aggregated and then emitted to the formatter once the subtest is
  complete. This suggests buffering or line-level emission strategies are
  expected in parallel contexts to preserve readability.
- Getopt::Long optional arguments set numeric options to 0 and string options
  to an empty string when the value is omitted, which matters for `-x` without
  an argument. (Getopt::Long docs)

## Goals
- Add `-x, --expand[=N]` to `prove` to expand subtests in console output.
- Support nested expansion to depth N (default 1 when `-x` is supplied).
- Show subtest progress (`run/planned`) while a subtest is running.
- Show final status (`ok` / `not ok`) at the correlated summary test point.
- Work with parallel execution (`jobs > 1`) without suppressing expansion.
- Preserve TAP parsing and aggregation semantics.

## Non-Goals
- Do not alter TAP::Parser semantics or treat subtests as independent test
  programs in the aggregator.
- Do not change TAP emitted by test programs.
- Do not expand subtest flavors that lack a stable name (e.g., unadorned
  subtests) unless we can derive a sensible display name; see "Edge Cases".
- Do not add new formatter types or change non-console formatters.

## UX / CLI
### New option
- `prove -x` or `prove --expand`: expand subtests to depth 1.
- `prove -x 2` / `prove --expand=2`: expand subtests to depth 2.

### Behavior
- Default output unchanged when `-x` is not specified.
- Expansion is suppressed when `--verbose` is used to avoid duplicate raw TAP.
- Expansion works with parallel jobs (`-j N`), using line-based output that
  coexists with the parallel "ruler".

## Technical Constraints and Opportunities
- The TAP grammar in this repo does not parse indented subtest lines (regexes
  are anchored at column 0), so subtest expansion must parse `result->raw`
  lines in the formatter. (See `TAP::Parser::Grammar` and `Result->raw`.)
- `TAP::Formatter::Console::ParallelSession` currently only processes test
  results and ignores comment/unknown lines. Subtest expansion requires all
  raw lines to flow through expansion logic even in parallel mode.
- The parallel ruler uses carriage-return updates; subtest output must ensure
  it prints a newline before emitting lines to avoid overwriting the ruler.

## Complexity and Feasibility by Requirement
1) **CLI option `-x/--expand[=N]`**
   - Low complexity. Getopt::Long already in use; we need careful optional
     argument parsing (see API scrutiny below). Feasible.
2) **Nested subtest expansion**
   - Medium complexity. Requires an indentation-aware state machine and a
     stack to track nested subtests. Feasible within formatter.
3) **Parallel expansion**
   - Medium complexity. We must ensure subtest lines can be emitted without
     corrupting the parallel ruler and while multiple sessions are active.
     Requires a small refactor in `ParallelSession::result`. Feasible.

## Scrutiny of Newly Depended APIs
- **Getopt::Long optional arguments**: For `-x` with optional value, numeric
  optional args default to 0 when omitted; string optional args default to an
  empty string. To distinguish "no value" from an explicit numeric value, use
  an optional *string* (`:s`) and validate/normalize it.
- **`TAP::Parser::Result->raw`**: Provides the original line text. We must
  normalize (chomp) a copy before regex matching because the raw line may
  include trailing newlines (parser iterators typically return lines with
  newline endings). No API change needed.

## Parsing Model (Formatter-side)
We detect subtests by examining raw TAP lines in the formatter, independent of
TAP::Parser tokens. This aligns with TAP format guidance: subtests are indented
by 4 spaces and closed by a correlated summary test point.

### Definitions
- **Indent level**: number of leading spaces divided by 4 (only if divisible).
- **Subtest depth**: top-level subtest = depth 1, nested subtest = depth 2, etc.
  Depth is `comment_indent_level + 1`.

### Start of subtest
- Match `^\s*#\s*Subtest:\s*(.*?)\s*$` after removing leading spaces.
- Compute depth from indent level.
- Only expand if depth <= `expand_max`.
- Push subtest onto a stack: `{ depth, name, planned, run, failed }`.

### Subtest content
- Plan line: `^1\.\.(\d+)` at indent level == subtest depth.
- Test line: `^(not )?ok\b` at indent level == subtest depth.
- Update `run`, `planned`, and `failed`.
- Emit progress as `run/planned` unless `run == planned` and we expect a
  correlated summary test point next.

### End of subtest
- A test line at indent level == (subtest depth - 1) closes the subtest at
  depth `indent + 1`. The correlated summary test point is part of the parent
  stream and provides final status.
- Emit `ok` or `not ok` for the subtest, then pop the stack.
- The same line should still count as a test line for the parent subtest (if
  any), so close deepest subtests first, then process it as a test line for
  the parent.

### Depth Limit (`expand_max`)
- Subtests deeper than `expand_max` are not tracked; their indented content is
  ignored for expansion. The correlated summary test point still contributes to
  the parent's progress (since it is at the parent indent).

## Output Formatting
### Indentation and alignment
- Display indent: two spaces per depth (`'  ' x depth`).
- Maintain `subtest_longest[$depth]` to align dot padding per depth.
- Format:
  ```
  sub_pretty = ( '  ' x $depth ) . $name
             . ('.' x ($subtest_longest[$depth] + 2 - length $name)) . ' ';
  ```

### Progress updates
- For each test line within a subtest, increment `run`.
- If plan known: show `run/planned`; otherwise `run/?`.
- Skip the final `N/N` progress line if we expect the correlated summary line
  to arrive immediately after `run == planned`.

### Final status
- On correlated summary test point: emit `sub_pretty . "ok"` or `"not ok"`.

### Interaction with top-level progress
- Once any subtest output is emitted for a test program, suppress further
  top-level carriage-return count updates for that test (serial mode).
- In parallel mode, emit a newline before the first subtest line so the
  parallel ruler is not overwritten; subsequent ruler updates can continue on
  the current line.

## Parallel Execution Strategy
Parallel runs require expansion without suppressing output. This is feasible by
line-based emission with minimal interference:
- Always run subtest parsing for every `result` line in
  `TAP::Formatter::Console::ParallelSession`, regardless of result type.
- When a subtest line is emitted, ensure we print a newline first (if the last
  output did not end with one) so we do not overwrite the ruler.
- Keep the existing ruler behavior; it will continue to update on the current
  line after subtest output. This yields readable output without requiring
  cross-session buffering.

If readability issues arise, an alternate option is to buffer subtest lines per
session and flush them at `close_test`, similar to Test2's buffered subtests,
which emit subtest output only after completion. This preserves grouping but
reduces live progress.

## Implementation Plan (Phased)
### Phase 1: CLI and Harness Plumbing
Dependencies: none.
- **`lib/App/Prove.pm`**
  - Add option parsing for `-x/--expand` with optional value.
  - Recommended parsing approach:
    ```perl
    # optional string to distinguish -x (empty) from -xN
    'x|expand:s' => sub {
        my ( $opt, $val ) = @_;
        $val = 1 if !defined($val) || $val eq '';
        die "--expand expects a positive integer" unless $val =~ /^\d+$/ && $val > 0;
        $self->{expand} = $val;
    },
    ```
  - Add `expand` attribute/accessor to `@ATTR` and `mk_methods`.
  - In `_get_args`, pass `expand => $self->expand` when defined.
  - Update POD for `-x/--expand[=N]`.

- **`lib/TAP/Harness.pm`**
  - Add `expand` to `@FORMATTER_ARGS` so it is passed to formatters.

- **`lib/TAP/Formatter/Base.pm`**
  - Add `expand` to `%VALIDATION_FOR` as a passthrough (integer or undef).
  - Document `expand` in POD.

### Phase 2: Subtest Parsing Helper
Dependencies: Phase 1 (option available) but can be built independently.
- **New helper (preferred)**: `lib/TAP/Formatter/Console/Subtest.pm`
  - Encapsulate subtest state and parsing logic.
  - Public-ish methods:
    - `new( max_depth => $n )`
    - `consume_line($raw_line)` returns events: `progress`, `final`.
  - Events are small hashes: `{ depth, name, text }`.
- **Alternate**: Inline helper in `Console::Session` if a new module is not
  desired. This risks duplicating logic in `ParallelSession`.

### Phase 3: Serial Console Session Integration
Dependencies: Phase 2 helper.
- **`lib/TAP/Formatter/Console/Session.pm`**
  - Add per-session state:
    ```perl
    my $expand = $formatter->expand;
    my $subtest = TAP::Formatter::Console::Subtest->new(max_depth => $expand);
    my $subtest_output_started = 0;
    my @subtest_longest;
    ```
  - On each `result`, call helper with `$result->raw` to receive events.
  - Implement `emit_subtest_line` to:
    - Print a newline once before the first subtest line (if needed).
    - Update `subtest_output_started` and `newline_printed`.
  - Suppress top-level `show_count` updates when `subtest_output_started`.

### Phase 4: Parallel Console Session Integration
Dependencies: Phase 2 helper.
- **`lib/TAP/Formatter/Console/ParallelSession.pm`**
  - Ensure subtest parsing runs for every result, not only test results.
  - Reuse helper and `emit_subtest_line` from the base class. If necessary,
    override to insert a newline before subtest output so the ruler is not
    overwritten.
  - Keep current ruler logic; allow subtest output lines to interleave in
    parallel runs as needed.

### Phase 5: Tests and Fixtures
Dependencies: Phases 1-4.
- **Fixture**: `t/sample-tests/subtest_expand`
  - Deterministic TAP output with nested subtests (depth 2+), no sleeps.
  - Example structure:
    ```
    TAP version 14
    1..2
    # Subtest: outer
        1..2
        ok 1 - inner parent test
        # Subtest: inner
            1..1
            ok 1 - leaf
        ok 2 - inner
    ok 1 - outer
    ok 2 - top
    ```
- **Test file**: `t/expand-subtests.t`
  - Use `IO::c55Capture` to capture output.
  - Scenarios:
    1) No `-x`: no indented subtest summary lines.
    2) `-x` (depth 1): shows only top-level subtest lines.
    3) `-x 2`: shows nested subtest lines.
    4) `-x -v` (verbose): expansion suppressed.
    5) `-x -j2` with two test files: expansion present (match using regex,
       ignore ruler lines).
  - For parallel test, assert presence of subtest summary lines for both test
    files without requiring strict ordering.

### Phase 6: Documentation and Manifest
Dependencies: Phase 1.
- Update POD in `lib/App/Prove.pm` and `lib/TAP/Formatter/Base.pm`.
- Add new test files/fixtures to `MANIFEST` if release tooling requires it.

## Files to Modify/Create
- Modify: `lib/App/Prove.pm`
- Modify: `lib/TAP/Harness.pm`
- Modify: `lib/TAP/Formatter/Base.pm`
- Modify: `lib/TAP/Formatter/Console/Session.pm`
- Modify: `lib/TAP/Formatter/Console/ParallelSession.pm`
- Add: `lib/TAP/Formatter/Console/Subtest.pm` (preferred helper)
- Add: `t/sample-tests/subtest_expand`
- Add: `t/expand-subtests.t`
- Modify (if required): `MANIFEST`

## Edge Cases
- No plan inside subtest: show `run/?` progress and still show final status.
- Plan `1..0`: no progress lines; final status still printed.
- Mismatched summary description: close subtest on first correlated test line
  regardless of description text.
- Nested subtests deeper than `expand_max`: ignore expansion and progress for
  those levels, but parent progress still updates.
- YAML blocks and diagnostic lines: ignored for progress (indent not multiple
  of 4 or non-matching patterns).
- Unadorned/buffered subtests: ignored unless we can derive a name safely.

## Backward Compatibility
- No behavior change unless `-x/--expand` is specified.
- Aggregated test counts and exit codes are unchanged.
- Non-console formatters receive `expand` but may ignore it.

## Future Work (Optional)
- Support unadorned or buffered subtests with inferred names.
- Improve parallel readability by grouping buffered subtest output per test.
- Add environment variable support (`HARNESS_OPTIONS=expand=2`).
