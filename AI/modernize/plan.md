## Summary
Modernize `prove`'s interactive console output to a Vitest-like experience while preserving non-TTY output: UTF status glyphs (U+2713/U+00D7), a poll-driven spinner, millisecond timing everywhere, and richer color segmentation. Non-interactive output remains byte-for-byte stable except for time-unit changes. Vitest's reporter examples show checkmark-based status and millisecond durations as a reference for the intended feel. Jest's tooling also uses platform-aware symbol handling, reinforcing the need for an ASCII fallback. 

What IS -> what WILL BE (high-level):
- IS: per-test completion line prints literal "ok"; subtest expansion prints "ok"/"not ok". WILL BE: TTY output shows U+2713/U+00D7 in green/red, with `--noutf` restoring "ok"/"not ok"; non-TTY remains unchanged.
- IS: status updates refresh roughly once per second only when TAP lines arrive. WILL BE: 100ms default poll tick on TTY with a spinner frame advancing each tick; `--poll=N` overrides.
- IS: time outputs mix seconds and ms based on Time::HiRes and Benchmark::timestr. WILL BE: all time displays use ms with rounding rules, including summary and per-test CPU/wallclock.
- IS: console color output is coarse (whole-line success/failure). WILL BE: segmented color styling: muted labels/dot leaders, white names/counts, green/red status glyphs, amber ms digits with dim suffix.

Complexity / feasibility by requirement (and comparable OSS references):
- UTF status glyphs: low complexity, localized to formatter output (Vitest docs show checkmark status in reporter output). Feasible with new formatter helpers and `--noutf` fallback. 
- Polling + spinner: medium complexity due to harness/multiplexer loop changes and tick hooks; feasible using IO::Select timeouts and a formatter tick method.
- Millisecond timing: medium complexity; requires replacing Benchmark::timestr and refactoring time_report formatting. Feasible with new ms formatting helper.
- Color segmentation: medium complexity; requires segment-aware rendering to avoid length issues with ANSI codes. Feasible with formatter helper that returns colored segments only when color is enabled.
- CLI/docs/tests: medium complexity; new options + TTY simulation tests + updated summary regexes.

## Architecture Documentation
New or changed components:
- `App::Prove` CLI: add `--poll` and `--noutf` options, plus new attributes.
- Formatter configuration: new `poll` (ms) and `utf`/`use_utf` flags, defaulted for TTY output.
- Formatter tick hook: new `tick()` path for interactive updates when no TAP output arrives.
- `TAP::Parser::Multiplexer`: add timeout-aware polling (`can_read($timeout)`), used by harness loops.
- Console formatter helpers: segment-aware colorization, status glyph mapping, spinner frames.
- Time formatting: shared ms formatter used by `TAP::Formatter::Session` and summary output.

New or changed processes/threads:
- Harness main loops (parallel + single) will poll with a timeout (default 100ms for TTY) and invoke formatter tick when idle.

New or changed interfaces:
- `App::Prove`: `--poll=N`, `--noutf`.
- `TAP::Formatter::Base`/`Console`: new accessors (`poll`, `use_utf` or `utf`) and `tick()`.

New or changed data flows:
- CLI -> App::Prove -> TAP::Harness args -> Formatter/session state.
- Poll interval used by harness to drive multiplexer/iterator polling and tick cadence.

## Detailed Design and Implementation Plan

### Phase 1 - CLI plumbing and configuration defaults
- Add new attributes in `App::Prove` for `poll` and `utf` (or `noutf`), plus getter/setters.
- Extend `process_args` to parse `--poll=N` with explicit validation (positive integer) and `--noutf`.
  - Suggested parsing snippet (ASCII only):
    ```perl
    'poll=s' => sub {
        my ( $opt, $val ) = @_;
        croak '--poll expects a positive integer (milliseconds)'
          unless defined $val && $val =~ /\A\d+\z/ && $val > 0;
        $self->{poll} = $val;
    },
    'utf!' => \$self->{utf},
    ```
- Wire these into `_get_args` so they propagate to `TAP::Harness` / formatter args.
- Update `TAP::Harness` to accept `poll`/`utf` as formatter args (append to `@FORMATTER_ARGS`).
- Define default poll behavior in formatter:
  - If `poll` explicitly set, use it.
  - If not set and output is a TTY, default to 100ms.
  - If not a TTY, disable polling (undef).
- Define default utf behavior in formatter:
  - If `utf` explicitly set (via `--noutf` or `--utf`), honor it.
  - Otherwise, default to true for TTY output.

### Phase 2 - Millisecond formatting and summary line
- Introduce a shared ms formatting helper (preferably in `TAP::Base` for reuse):
  - Input seconds -> output string (e.g., `0ms`, `<1ms`, `123ms`).
  - Round to nearest ms for values >= 1ms; `<1ms` for 0 < ms < 1.
- Update `TAP::Formatter::Session::time_report`:
  - Always output ms for wallclock and CPU times, regardless of Time::HiRes.
  - Keep existing CPU breakdown fields (usr/sys/cusr/csys) but render each as ms tokens.
- Replace Benchmark::timestr usage in summary:
  - In `TAP::Formatter::Base::summary`, call `aggregate->elapsed` and format:
    `Files=..., Tests=..., <wallclock> wallclock (<usr> usr + <sys> sys = <cpu> CPU)`
  - Ensure ms tokens follow rounding rules; drop the "secs" label.

### Phase 3 - Status glyphs and color segmentation helpers
- Add formatter helpers in `TAP::Formatter::Console`:
  - `_use_utf` (computed from `utf` flag + TTY).
  - `_status_token($ok)` returns "ok"/"not ok" or U+2713/U+00D7.
  - `_spinner_frames` returning UTF frames (U+2807, U+280B, U+2819, U+2838, U+28B0, U+28A0, U+28C4, U+2846) or ASCII frames (| / - \\).
  - `_color_span($color, $text)` or `_render_segments(@segments)` that emits colors only when color is enabled.
  - Color palette helpers for muted grey (labels, dot leaders), white (names/counts), success/failure, and amber ms digits + dim suffix.
- Update per-test completion lines:
  - Replace `_make_ok_line` or override close_test output to use `_status_token(1)` and apply green to the glyph only.
  - Ensure time_report is colorized with amber digits and dim suffix when color is enabled.
- Update subtest expanded output in `Console::Session` and `Console::ParallelSession`:
  - Use `_status_token($ok)` instead of literal "ok"/"not ok".
  - Use existing success/failure colors for glyphs.
- Maintain non-TTY behavior: if not interactive or `--noutf`, output remains ASCII.

### Phase 4 - Polling, spinner tick, and multiplexer changes
- Add timeout-aware polling to `TAP::Parser::Multiplexer`:
  - Accept optional timeout (seconds) in `next()` or a new `next_with_timeout()` method.
  - When timeout expires with no ready handles, return empty list and allow caller to decide.
- Update harness loops:
  - Parallel: while `$mux->parsers`, call `next($timeout)`; if no result, call `formatter->tick` and continue.
  - Single: when poll enabled and parser has select handles, use `IO::Select->can_read($timeout)` before calling `parser->next`; call `formatter->tick` on timeout.
- Implement `tick`:
  - `TAP::Formatter::Base::tick` = no-op.
  - `TAP::Formatter::Console::tick` delegates to active sessions or shared context.
  - `Console::Session::tick` updates the progress line with the next spinner frame (muted grey) when no subtest output is active.
  - `Console::ParallelSession::tick` updates the shared ruler line with spinner (or calls SUPER when only one active session).

### Phase 5 - Tests and documentation
- Update CLI docs:
  - `bin/prove` OPTIONS list: add `--poll=N` and `--noutf`.
  - `lib/App/Prove.pm` POD: add attributes and usage notes.
- Update examples/POD to show ms summary format (e.g., `lib/TAP/Harness/Beyond.pod`).
- Tests (see detailed test plan below):
  - CLI option parsing and validation for `--poll` and `--noutf`.
  - Time format changes (summary + per-test `time_report`).
  - UTF vs ASCII glyphs in interactive mode.
  - Spinner tick cadence and color segmentation in TTY output (with pseudo-tty or simulated output).

## Code References to Impacted Code
- `lib/App/Prove.pm:45` - add `poll`/`utf` attributes and CLI parsing.
- `bin/prove:24` - update OPTIONS documentation.
- `lib/TAP/Harness.pm:49` - add `poll`/`utf` to formatter args; use poll in aggregate loops.
- `lib/TAP/Parser/Multiplexer.pm:96` - add timeout-aware `next` behavior.
- `lib/TAP/Formatter/Base.pm:270` - replace summary time formatting with ms output and segmented colors.
- `lib/TAP/Formatter/Session.pm:190` - update `time_report` to ms formatting.
- `lib/TAP/Formatter/Console.pm:40` - add status glyph and color segmentation helpers.
- `lib/TAP/Formatter/Console/Session.pm:110` - update per-test progress/output and add tick/spinner.
- `lib/TAP/Formatter/Console/ParallelSession.pm:80` - update ruler output and subtest final glyphs.
- `lib/TAP/Formatter/File/Session.pm:70` - ensure ok line uses ASCII, but time report now ms.
- `lib/TAP/Parser/Aggregator.pm:246` - (optional) adjust elapsed_timestr or add ms helper.
- `lib/TAP/Harness/Beyond.pod:91` - update summary example to ms format.
- `t/harness.t` and `t/file.t` - update summary regexes and ms formatting expectations.
- `t/prove.t` - add `--poll`/`--noutf` parsing tests.
- (new) `t/console-spinner.t` - TTY spinner/glyph/color tests.

## Detailed Test Plan
- CLI parsing:
  - `t/prove.t`: add cases for `--poll=100`, `--poll=1000`, `--poll=0` (error), `--poll=abc` (error), and `--noutf`.
  - Assert `poll` stored in args; `utf` flag set to 0 when `--noutf`.
- Summary line format:
  - `t/harness.t` and `t/file.t`: update regex to match `\d+ms wallclock` and CPU ms format (no "secs").
  - Add explicit `<1ms` coverage by injecting a mocked Benchmark elapsed (or stubbing formatter helper) if feasible.
- Per-test time report:
  - Add unit test for `TAP::Formatter::Session::time_report` using fixed start/end times (override `get_time` or parser times) to assert `0ms`, `<1ms`, `1ms` rounding.
- UTF glyphs vs ASCII:
  - New test file that runs a console session with a pseudo-tty (IO::Pty if available) to assert U+2713/U+00D7 appear by default, and ASCII when `--noutf` is set.
  - Skip if IO::Pty is unavailable.
- Spinner tick cadence:
  - New test that sets `poll=50` and uses a stub parser that emits no output for N ticks; assert spinner frames advance (UTF vs ASCII depending on utf flag) and are muted grey when color enabled.
  - For non-TTY, assert no spinner output.
- Color segmentation:
  - Add test for summary line segmentation (labels grey, counts white, ms digits amber + dim suffix) by patching `_set_colors` or `_output` to capture color calls.

## Options and Open Questions
- Spinner placement in parallel mode: append to ruler tail vs replace trailing '=' to keep WIDTH=72? Option A: append (simpler, may widen line). Option B: replace final char to keep width stable.
  Answer: Option B
- Color palette mapping: use `bright_black` for muted grey vs `white` + `dark/faint` attribute; use `bright_yellow` for digits and `yellow dark` for the `ms` suffix. Need to pick a mapping that works on 8/16-color terminals.
  Answer: use whichever is more likely to be more visible on the most common terminals using standard colors
- `--utf` counterpart: use `utf!` in Getopt (accepts `--utf` and `--noutf`) or only `--noutf`. Decide whether to document `--utf`.
  Answer: adding `--utf` is ok if that is more natural for Getopt
- Tick suppression during subtest expansion: should spinner pause when subtest progress lines are active to avoid overwriting? Proposed: pause when `subtest_state->{progress_active}` is true.
  Answer: the spinner should move to appear at the end of the current subtest line
- Non-selectable iterators: polling may not improve tick cadence if parser handles are not select-able; confirm acceptable fallback (no spinner tick) vs implementing iterator-level timeouts.
  Answer: no spinner tick on non-select-able parser handles
