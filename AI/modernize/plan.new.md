## Summary
Modernize `prove`'s interactive console output to a Vitest-like experience while preserving non-TTY output (except for the required time-unit changes): use UTF status glyphs (U+2713/U+00D7) on TTY, add a poll-driven spinner, report wallclock/CPU times in milliseconds everywhere, and apply richer per-span coloring. Add CLI controls for UTF output (`--noutf`) and polling cadence (`--poll=N` in ms, defaulting to 100ms on TTY with `--poll=1000` restoring the previous cadence), update documentation, and expand tests to lock in behavior.

Comparable OSS references and API behavior checks (used to refine design):
- Vitest's default reporter output uses checkmark-style pass indicators and millisecond durations in its CLI examples, matching the intended UX target.
- `cli-spinners` documents braille spinner frames and a similar polling cadence (commonly ~80ms), consistent with the planned spinner style.
- `figures` documents Unicode status symbols with ASCII/Windows fallbacks, reinforcing the need for `--noutf` behavior on non-UTF output.
- `IO::Select->can_read($timeout)` accepts a fractional-second timeout and returns an empty list on timeout (and undef on error with `$!` set), which enables a non-blocking poll/tick loop without misclassifying timeouts as completion.

Complexity / feasibility by requirement:
- UTF status glyphs: low complexity, localized to console formatter output (per-test and subtest final lines). Feasible with a small status-token helper and TTY gating.
- Polling + spinner: medium complexity because it touches multiplexer/harness loops and requires a formatter tick path; feasible using `IO::Select` timeouts and session-level spinner state.
- Millisecond timing: medium complexity; requires a shared ms formatter and replacement of `Benchmark::timestr` in summary output plus refactoring `time_report` to be ms-only. Feasible with small helper changes.
- Color segmentation: medium complexity; requires segment-aware rendering helpers and updates to summary/progress lines. Feasible by introducing a console-only segment renderer and palette mapping.
- CLI/docs/tests: medium complexity; new options and new TTY simulation tests; feasible with existing test scaffolding and optional IO::Pty.

## Architecture Documentation
New or changed components:
- `App::Prove`: new `poll` and `utf` (or `noutf`) attributes, CLI parsing, and args propagation.
- `TAP::Harness`: pass `poll`/`utf` into formatter args; add polling-aware aggregation loops.
- `TAP::Formatter::Base`: accept `poll`/`utf`, add ms-formatting helper, and replace summary runtime formatting with ms-aware output.
- `TAP::Formatter::Console`: add status-token mapping, spinner frame selection, segment renderer, and palette helpers (muted grey, white, amber digits + dim suffix).
- `TAP::Formatter::Console::Session` and `::ParallelSession`: add `tick()` support and spinner state; update per-test and subtest final output to use status tokens and segmented colors.
- `TAP::Parser::Multiplexer`: optional timeout-aware polling to support tick cadence.
- (Optional) `TAP::Parser::Aggregator`: new helper to expose elapsed times in raw seconds/ms (if summary wants data from here instead of direct array access).

New or changed processes or threads:
- Harness main loops (serial + parallel) become poll-aware: they wait with timeouts and call formatter `tick()` when idle.

New or changed interfaces:
- CLI: `--poll=N` (ms) and `--noutf` (plus optional `--utf` if using `utf!` in Getopt).
- Formatter args: `poll` and `utf` (passed from `App::Prove` -> `TAP::Harness` -> formatter).
- Formatter/session: new `tick()` method on formatter and console sessions.

New or changed data flows:
- CLI options -> `App::Prove` attributes -> `_get_args` -> `TAP::Harness` -> formatter/session state (poll cadence, UTF mode).
- Poll timeout -> multiplexer/iterator loops -> formatter tick -> console spinner update.

New or changed event-driven or timer processing:
- Poll-driven tick path using `IO::Select->can_read($timeout)` with ms -> seconds conversion, gated by TTY and selectable handles.

New or changed network programming:
- None.

New or changed data stores:
- None.

## Detailed Design and Implementation Plan

### Phase 1 - CLI plumbing, formatter args, and TTY defaults
- Focus: add CLI options and propagate configuration into formatter/session state.
- Add new attributes in `App::Prove` for `poll` and `utf` (or `noutf`).
- Extend `process_args` to parse `--poll=N` and `--noutf`:
  - Validate N is a positive integer (milliseconds); on invalid input, emit a clear error message and non-zero exit.
  - Prefer `utf!` in Getopt to allow `--utf` and `--noutf`; document only `--noutf` unless the team wants symmetry in docs.
  - Example parsing pattern (ASCII-only):
    ```perl
    'poll=s' => sub {
        my ( $opt, $val ) = @_;
        croak '--poll expects a positive integer (milliseconds)'
          unless defined $val && $val =~ /\A\d+\z/ && $val > 0;
        $self->{poll} = $val;
    },
    'utf!' => \$self->{utf},
    ```
- Wire `poll`/`utf` into `_get_args` so they are passed to `TAP::Harness` formatter args.
- Update `TAP::Harness` `@FORMATTER_ARGS` to include `poll` and `utf` so they propagate into formatter construction.
- Add `poll` and `utf` to `TAP::Formatter::Base` validation/methods (pass-through accessors), ensuring unknown-arg checks still pass.
- Define defaults at formatter/session level:
  - `poll`: if explicitly set, use it; if unset and output is TTY (and `HARNESS_NOTTY` is not set), default to 100ms; if non-TTY, treat as disabled (undef).
  - `utf`: if explicitly set, honor it; otherwise default to true for TTY output and false for non-TTY (to preserve byte-for-byte non-TTY output).

### Phase 2 - Polling infrastructure and tick path
- Focus: introduce timeout-aware polling and a formatter tick hook without altering non-tty output.
- `TAP::Parser::Multiplexer`:
  - Add timeout support, either by:
    - Extending `next($timeout)` with optional timeout (seconds, float) and a `timed_out` flag, or
    - Adding `next_with_timeout($timeout)` to avoid changing existing call semantics.
  - Use `IO::Select->can_read($timeout)`; on timeout it returns an empty list and does not set `$!`. On error it returns undef with `$!` set. Treat timeout as "no result yet" rather than "parsers exhausted".
  - Continue to drain non-selectable parsers first (the `avid` queue). For non-selectable iterators, do not tick (matches the resolved decision).
- `TAP::Harness::_aggregate_parallel`:
  - Restructure loop to poll when `formatter->poll` is enabled and `SELECT_OK` is true:
    - While parsers exist, call mux `next` with timeout.
    - If no result and parsers remain, call `formatter->tick` and continue (do not exit loop).
    - Keep existing scheduler-fill logic intact.
  - Keep non-poll behavior unchanged when `poll` is undef or when `SELECT_OK` is false.
- `TAP::Harness::_aggregate_single`:
  - If `poll` is enabled and `parser->get_select_handles` returns handles, create an `IO::Select` and `can_read($timeout)` before calling `parser->next`.
  - On timeout, call `formatter->tick` (passing the active session if needed) and continue.
  - If no selectable handles or poll disabled, preserve current blocking `parser->next` loop.
- Formatter tick hook:
  - Add `TAP::Formatter::Base::tick` as a no-op.
  - Add `TAP::Formatter::Console::tick` to fan out to active session(s) and update spinner state.
  - Add session-level `tick` to update the progress line/ruler with the next spinner frame when appropriate.

### Phase 3 - Millisecond formatting and summary line
- Focus: unify time formatting in ms and remove `Benchmark::timestr` dependency in summary.
- Create a shared ms formatter helper (best placed in `TAP::Base` for reuse, or in `TAP::Formatter::Base` if we want formatter-only scope):
  - Input: seconds (float or integer). Output: string token `Nms` with rounding to nearest ms; `<1ms` for non-zero durations under 1ms; `0ms` only for true zero.
  - Provide a companion helper for colored `ms` segments (digits vs suffix) in console-only paths.
- Update `TAP::Formatter::Session::time_report`:
  - Always output ms for wallclock and CPU segments, regardless of `Time::HiRes` availability.
  - Keep the existing CPU breakdown fields (usr/sys/cusr/csys) but format each as `Nms` using the helper.
- Replace `Benchmark::timestr` usage in summary:
  - In `TAP::Formatter::Base::summary`, call `aggregate->elapsed` and extract values (Benchmark object holds `(real, user, sys, cuser, csys, iters)` as documented).
  - Format summary as:
    `Files=..., Tests=..., <wall> wallclock (<usr> usr + <sys> sys = <cpu> CPU)`
    where `<wall>`, `<usr>`, `<sys>`, and `<cpu>` are `Nms` tokens.
  - Use `cpu = usr + sys` to match the required format; keep child CPU breakdown in per-test `time_report` only.
- (Optional) add `TAP::Parser::Aggregator::elapsed_ms` or `elapsed_values` helper to avoid raw array access in formatter code.

### Phase 4 - UTF status glyphs, spinner frames, and color segmentation
- Focus: update console output formatting to use UTF tokens on TTY, spinner feedback, and segmented colors.
- Add console helpers:
  - `_is_interactive` (TTY + not `HARNESS_NOTTY`) and `_use_utf` (TTY + `utf` true).
  - `_status_token($ok)` returns `U+2713`/`U+00D7` (TTY + UTF) or `ok`/`not ok` (ASCII fallback or non-TTY).
  - `_spinner_frames` returns UTF braille frames (U+2807, U+280B, U+2819, U+2838, U+28B0, U+28A0, U+28C4, U+2846) or ASCII frames (`|`, `/`, `-`, `\`) when `--noutf` or non-TTY.
  - `_render_segments(@segments)` emits colors only when colorization is enabled; otherwise concatenates text. Each segment should include `{ text => '...', color => '...' }` and reset color between segments.
  - Palette helpers:
    - muted grey (labels + dot leaders + spinner): prefer `white` + `dark` if needed.
    - white for names/counts (non-dim).
    - success/failure colors use existing `_success_color`/`_failure_color` for glyphs.
    - amber ms digits: `yellow`; ms suffix: `yellow` + `dark`
- Update per-test completion lines (`Console::Session`):
  - Replace `_make_ok_line` usage with a console-specific path that outputs the status glyph token only (green/red) and keeps the rest of the line segmented (name in white, dot leaders grey, time report with amber ms digits and dim suffix).
  - Keep ASCII output for non-TTY or `--noutf`.
- Update subtest expanded output (`Console::Session` and `Console::ParallelSession`):
  - Use `_status_token($ok)` in final subtest lines, with green/red applied to the glyph only.
  - Ensure subtest names are white and dot leaders are grey when color is enabled.
- Update progress lines (serial session) and ruler (parallel session):
  - Append the spinner frame at the end of the current progress line; when subtest progress output is active, update the spinner at the end of that line (resolved decision).
  - For parallel output, keep the 72-column width by replacing the last character with the spinner frame (resolved decision: Option B).
- Ensure non-TTY output remains unchanged:
  - Gate UTF glyphs and spinner to interactive TTY only.
  - If `--noutf`, force ASCII tokens and ASCII spinner frames.

### Phase 5 - Documentation and tests
- Focus: update CLI docs and add/adjust tests to cover new behavior.
- Documentation updates:
  - `bin/prove` help: add `--poll=N` and `--noutf` options (mention ms). If `--utf` is supported via `utf!`, decide whether to document it explicitly.
  - `lib/App/Prove.pm` POD: document new options and defaults (100ms poll on TTY; `--poll` CLI-only, no env/HARNESS_OPTIONS support).
  - `lib/TAP/Harness/Beyond.pod`: update the summary example to ms format without `secs`.
- Test updates/additions:
  - `t/prove.t`: add parsing/validation tests for `--poll` (valid integers; reject 0/negative/non-numeric), and for `--noutf` toggling the formatter `utf` flag.
  - `t/harness.t` and `t/file.t`: update summary regexes to match ms output and no `secs` label; add explicit coverage for `<1ms` and `0ms` (use a deterministic helper or stub the formatter ms helper to avoid timing flakiness).
  - New test for `TAP::Formatter::Session::time_report` ms formatting and rounding rules (simulate start/end times and CPU times).
  - New console/TTY tests for UTF glyphs and spinner cadence:
    - Use `IO::Pty` when available to force TTY output, capture output and assert default UTF glyphs appear and ASCII output appears under `--noutf`.
    - Provide skip logic when `IO::Pty` is unavailable.
  - Color segmentation tests:
    - Force `--color` and capture output; assert that labels/dot leaders use the muted grey color tokens and ms digits/suffix use the amber/dim pairing.
    - Consider stubbing `_set_colors` to record color calls rather than asserting raw ANSI output.
  - Spinner tick behavior tests:
    - Use a stub parser that yields no output for N ticks; assert spinner frames advance and are rendered in muted grey when color is enabled.
    - Ensure no spinner output on non-TTY or when `poll` is disabled.

## Code References to Impacted Code
- `lib/App/Prove.pm:24` - add `poll`/`utf` attributes and extend `process_args` parsing for `--poll` and `--noutf`.
- `lib/App/Prove.pm:290` - propagate `poll`/`utf` through `_get_args` to `TAP::Harness`.
- `bin/prove:24` - update OPTIONS help text to include `--poll` and `--noutf`.
- `lib/TAP/Harness.pm:56` - extend `@FORMATTER_ARGS` and pass `poll`/`utf` into formatter args.
- `lib/TAP/Harness.pm:617` - update parallel aggregation loop for timeout-aware polling and `tick`.
- `lib/TAP/Harness.pm:647` - update serial aggregation loop for timeout-aware polling and `tick`.
- `lib/TAP/Parser/Multiplexer.pm:96` - add timeout-aware `next`/`next_with_timeout` behavior.
- `lib/TAP/Formatter/Base.pm:20` - add `poll`/`utf` validation and accessors; update summary formatting to ms.
- `lib/TAP/Formatter/Session.pm:190` - update `time_report` to ms formatting.
- `lib/TAP/Parser/Aggregator.pm:236` - optionally add `elapsed_ms` or expose raw elapsed values for summary formatting.
- `lib/TAP/Formatter/Console.pm:15` - add status token, spinner frames, and segment-rendering helpers.
- `lib/TAP/Formatter/Console/Session.pm:60` - update per-test output lines to use UTF tokens and segmented colors; add `tick`/spinner state.
- `lib/TAP/Formatter/Console/ParallelSession.pm:60` - update ruler rendering to include spinner and segment colors; add `tick`.
- `lib/TAP/Harness/Beyond.pod:91` - update summary example to ms format.
- `t/prove.t` - add `--poll` and `--noutf` parsing tests.
- `t/harness.t` and `t/file.t` - update summary regex expectations for ms output.
- `t/expand-subtests.t` - verify no change required for non-TTY (HARNESS_NOTTY) output; keep as regression.
- (new) `t/console-spinner.t` - add TTY spinner/glyph/color tests (skipped if no IO::Pty).

## Detailed Test Plan
- CLI parsing and validation (`t/prove.t`):
  - Add cases for `--poll=100`, `--poll=1000`, `--poll=0`, `--poll=-1`, `--poll=abc`.
  - Assert invalid cases return non-zero status with clear error text.
  - Assert the default poll is 100ms on TTY when `--poll` is not set, and that `--poll=1000` restores the previous cadence.
  - Assert `--noutf` sets the formatter arg `utf` to false; if `--utf` is supported, add a positive toggle test.
- Summary ms output (`t/harness.t`, `t/file.t`):
  - Update expected regex to `\d+ms wallclock` and `(\d+ms usr \+ \d+ms sys = \d+ms CPU)`.
  - Add coverage for `<1ms` and `0ms` by injecting a deterministic ms formatter stub or by setting a known elapsed value in a mocked aggregator.
- `time_report` ms formatting:
  - Add a focused unit test for `TAP::Formatter::Session::time_report` with synthetic `start_time`, `end_time`, and `times` values to validate rounding and `<1ms` behavior.
- UTF glyphs vs ASCII:
  - New test file (TTY-required) that runs a console session under a pseudo-tty to assert U+2713/U+00D7 appear by default and `ok/not ok` when `--noutf` is set.
  - Skip the test if `IO::Pty` is unavailable.
- Spinner cadence:
  - New test that sets `poll=50` and uses a stub parser that produces no output for several ticks; assert spinner frames advance in the expected sequence and are muted grey when color is enabled.
  - Ensure spinner does not render for non-TTY or when poll is disabled.
- Color segmentation:
  - Capture output with `--color` and assert color calls are segmented: labels/dot leaders grey, names/counts white, ms digits amber with dim suffix, glyphs green/red.
  - Prefer capturing calls to `_set_colors` or a patched colorizer rather than raw ANSI to keep tests stable.

## Options and Open Questions
Major options (resolved):
- Parallel spinner placement: replace the trailing ruler character with the spinner frame to keep width fixed at 72 columns.
- `--utf` counterpart: use `utf!` for parsing symmetry but only document `--noutf` unless there is a preference to expose `--utf` in help/POD.

Ambiguities (resolved):
- Spinner behavior during subtest expansion: append the spinner to the active subtest progress line rather than suppressing it.
- Non-selectable iterators: do not tick/spin when handles are not select-able (avoid busy loops or incorrect timeouts).

Requirements that are insurmountably complex:
- None identified.

Requirements that are probably infeasible with the current technology stack:
- None identified.
