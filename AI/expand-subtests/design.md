# Expand Subtests in `prove` Output (-x/--expand)

## Summary
Add a `-x, --expand` option to `prove` that treats top-level subtests as
display-only child entries and prints their progress/results indented under
the parent test program. This is a formatter-only enhancement; it does not
change TAP parsing semantics or aggregated test counts.

Example raw TAP from `./ZuTest` (top-level subtests):

```
TAP version 14
1..5
ok 1 - true
ok 2 - true
# Subtest: foo
    1..2
    ok 1 - true
    ok 2 - true
ok 3 - foo
# Subtest: bar
    1..0
ok 4 - bar
# Subtest: baz
    1..5
    ok 1 - true
    ok 2 - true
    ok 3 - true
    ok 4 - true
    ok 5 - true
ok 5 - baz
```

Current output:

```
] prove ./ZuTest
./ZuTest .. ok
All tests successful.
Files=1, Tests=5,  5 wallclock secs ( 0.01 usr +  0.00 sys =  0.01 CPU)
Result: PASS
```

Desired output with `-x` while running:

```
] prove -x ./ZuTest
./ZuTest .. 4/5
  foo ..... ok
  bar ..... ok
  baz ..... 3/5
All tests successful.
Files=1, Tests=5,  5 wallclock secs ( 0.01 usr +  0.00 sys =  0.01 CPU)
Result: PASS
```

Final output after completion:

```
] prove -x ./ZuTest
./ZuTest .. ok
  foo ..... ok
  bar ..... ok
  baz ..... ok
All tests successful.
Files=1, Tests=5,  5 wallclock secs ( 0.01 usr +  0.00 sys =  0.01 CPU)
Result: PASS
```

## Goals
- Provide a new `prove` CLI option `-x/--expand` to display top-level subtests
  as indented child entries.
- Show subtest progress (`N/M`) while a subtest is running.
- Show subtest final status (`ok` / `not ok`) once the parent summary line is
  received.
- Preserve existing summary counts and TAP parsing.

## Non‑Goals
- Do not change TAP::Parser behavior or treat subtests as real test programs
  in the aggregator.
- Do not expand nested subtests (only top-level subtests).
- Do not alter behavior when `-x` is not specified.
- No changes to TAP output emitted by tests.

## UX / CLI
### New option
- `prove -x` or `prove --expand`: expand top-level subtests.

### Behavior
- Default output unchanged without `-x`.
- With `-x`, emit indented subtest lines under the parent test program.
- `--verbose` already prints raw TAP; expansion is suppressed to avoid
  duplicated output.
- When `jobs > 1` (parallel), expansion is suppressed to avoid interleaving
  and output corruption.

## Parsing Model (Formatter-side)
The TAP parser does not tokenize indented subtest lines. We therefore detect
subtests from raw TAP lines inside the formatter:

### Start of top-level subtest
- Detect `# Subtest: NAME` at column 0.
- Only start a new top-level subtest when no other top-level subtest is active.

### Subtest content
While a top-level subtest is active, consume indented lines:
- Lines with exactly 4 leading spaces are considered subtest content.
- Lines with more than 4 leading spaces are nested subtests or deeper content
  and are ignored for progress.

The subtest parser only looks for:
- Plan: `^\s{4}1\.\.(\d+)`
- Test line: `^\s{4}(not )?ok\b`

### End of top-level subtest
The subtest completes when the next top-level test line is seen
(the parent summary `ok N - NAME` line). We do not require the description to
match the subtest name; we end the subtest on the first top-level test line
while a subtest is active.

## Output Formatting
### Indentation
Indented subtest lines are prefixed by two spaces (`"  "`), aligned using
dot padding similar to top-level test names.

### Alignment
Maintain a per-session `subtest_longest` and compute dot padding:

```
sub_pretty = "  " . name . ("." x (subtest_longest + 2 - length(name))) . " ";
```

### Progress updates
- For each subtest test line, increment `run`.
- If a plan is known, display `run/planned`; otherwise `run/?`.
- To avoid a redundant final `N/N` line, skip printing the progress update
  if `run == planned` and the summary line is expected next.

### Final status
When the top-level test line that closes the subtest is seen:
- Print `sub_pretty . "ok"` or `sub_pretty . "not ok"` based on that result.

### Interaction with top-level progress
Once the formatter emits any expanded subtest line, suppress further top-level
carriage-return progress updates for that test program. This keeps output
stable and prevents overwriting subtest lines. The last top-level status line
(e.g. `./ZuTest .. 4/5`) remains visible.

## Implementation Plan
### 1) Add `-x/--expand` to `prove`
Files: `lib/App/Prove.pm`
- Add CLI option:
  - `GetOptions` entry: `'x|expand' => \$self->{expand}`.
- Add `expand` attribute/accessor (follow existing pattern).
- In `_get_args`, pass `expand => 1` when set so it flows into the harness.
- Update POD to document `-x, --expand`.

### 2) Plumb `expand` through `TAP::Harness`
Files: `lib/TAP/Harness.pm`, `lib/TAP/Formatter/Base.pm`
- Add `expand` to `@FORMATTER_ARGS` so it is forwarded to formatter constructors.
- Add `expand` to `%VALIDATION_FOR` in `TAP::Formatter::Base` with a simple
  passthrough validation.
- Add POD entry for `expand` in `TAP::Formatter::Base`.

### 3) Implement expand logic in console session
File: `lib/TAP/Formatter/Console/Session.pm`

Add state in `_closures`:

```
my $expand = $formatter->expand;
my $subtest_longest = 0;
my $subtest = undef; # hashref with name, planned, run, failed
my $subtest_output_started = 0;
```

Helper closures:
- `format_subtest_name($name)` → returns padded name with indent and dots.
- `emit_subtest_line($text)` → ensures newline once, prints line, marks
  `subtest_output_started`.

Result processing additions (in `result` closure, after `$plan` handling):

1) Start subtest
```
if ( $expand
     && !$subtest
     && $result->is_comment
     && $result->raw =~ /^#\s*Subtest:\s*(.+?)\s*$/ ) {
    $subtest = { name => $1, planned => undef, run => 0, failed => 0 };
    $subtest_longest = length($1) if length($1) > $subtest_longest;
}
```

2) Parse subtest lines
```
if ( $expand && $subtest ) {
    my $raw = $result->raw;
    if ( $raw =~ /^ {4}(\S.*)$/ ) {
        my $line = $1;
        if ( $line =~ /^1\.\.(\d+)/ ) {
            $subtest->{planned} = $1;
        } elsif ( $line =~ /^(not )?ok\b/ ) {
            $subtest->{run}++;
            $subtest->{failed} ||= defined $1;
            my $planned = defined $subtest->{planned} ? $subtest->{planned} : '?';
            my $run = $subtest->{run};
            if ( $planned eq '?' || $run < $planned ) {
                my $pretty = format_subtest_name($subtest->{name});
                emit_subtest_line( $pretty . "$run/$planned" );
            }
        }
    }
}
```

3) End subtest (on top-level test line)
```
if ( $expand && $subtest && $result->is_test && $result->raw !~ /^\s/ ) {
    my $pretty = format_subtest_name($subtest->{name});
    emit_subtest_line( $pretty . ( $result->is_ok ? "ok" : "not ok" ) );
    $subtest = undef;
}
```

4) Suppress top-level progress updates once subtest output starts
Wrap the existing `show_count` update:
```
if ( $show_count && $is_test && !$subtest_output_started ) { ... }
```

### 4) Parallel session behavior
File: `lib/TAP/Formatter/Console/ParallelSession.pm`
- No special handling when multiple jobs are active; expansion is suppressed.
- When only one active test, the code already defers to `SUPER::result`, which
  will perform expansion.

### 5) Documentation and help
File: `lib/App/Prove.pm` POD
- Add `-x, --expand` to the option list and explanation.

### 6) Tests
Add new test file: `t/expand-subtests.t`
Test matrix:
1) `prove ./t/sample-tests/subtest_expand`:
   - Without `-x`, output unchanged (no indented subtest lines).
2) `prove -x ./t/sample-tests/subtest_expand`:
   - Output includes indented `foo`, `bar`, `baz` lines.
3) `prove -x -v`:
   - Expansion suppressed (no extra indented summary lines).
4) `prove -x -j2`:
   - Expansion suppressed (no extra indented summary lines).

Fixture: `t/sample-tests/subtest_expand`
- Static TAP stream that prints a small subtest tree with deterministic output.
- No sleeps in tests; use fixed TAP to assert formatting.

### 7) MANIFEST
If required by the release process, add `design.md` and new test files to
`MANIFEST`.

## Edge Cases
- No plan in subtest: show `run/?` and still print final `ok/not ok`.
- Plan `1..0`: no progress lines; print final `ok`.
- Mismatched summary description: end subtest on first top-level test line.
- Nested subtests: ignored for expansion (lines indented >4 spaces).
- YAML blocks in subtests: ignored for progress; safe because only `1..N` and
  `ok/not ok` lines are parsed.

## Backward Compatibility
- No behavior change unless `-x` is specified.
- Aggregated results and exit codes unchanged.
- Default output untouched.

## Future Work
- Optional support for nested subtests (indent > 4) with recursive expansion.
- Support `HARNESS_OPTIONS=x` / `HARNESS_EXPAND=1` environment controls.
- Integrate expansion into the parallel ruler output when `jobs > 1`.
