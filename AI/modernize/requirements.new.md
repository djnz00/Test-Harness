## Summary
Modernize `prove`'s interactive console output to match a vitest-like feel: UTF status glyphs, tighter polling with a Codex-style spinner, millisecond time reporting everywhere, and richer color segmentation. Preserve non-interactive output for compatibility, add CLI controls for UTF and polling, and update docs/tests to lock in behavior.

## Goals
- Improve interactive UX: clearer pass/fail symbols, visible progress while waiting, and more readable coloring.
- Standardize time units to milliseconds (ms) across per-test and summary output.
- Provide user control for UTF glyphs and polling cadence.
- Keep machine-readable/non-TTY output unchanged.

## Non-Goals
- Do not change TAP semantics or non-interactive output formats.
- Do not add environment variable or HARNESS_OPTIONS support for `--poll`.
- Do not redesign output beyond the specified symbol/color/time changes.

## Product Requirements

### 1) Interactive UTF Status Symbols
- When running interactively on a TTY, replace the output `ok` with `✓` (green) and output `not ok` messages with `×` (red), matching vitest-style status symbols. Note: this does NOT relate to TAP input format, which must remain as is and TAP-compliant.
- Apply UTF status symbols consistently in:
  - Per-test completion lines.
  - Subtest expanded output where `ok` and `not ok` are currently emitted.
- Add a `--noutf` CLI option that disables UTF output. When set:
  - Restore the current `ok`/`not ok` outputs.
  - Use the ASCII spinner frames (see Polling/Spinner).
- UTF glyphs and spinner changes apply only to interactive TTY output; non-TTY output remains unchanged.

### 2) Polling Interval and Spinner Feedback
- Add `--poll=N` (milliseconds) to `prove`.
  - Validate N is a positive integer; reject invalid values with a clear error message and non-zero exit.
  - Propagate N through `App::Prove` into formatter/session configuration.
- Default interactive polling interval is reduced from 1000ms to 100ms.
  - Users can restore the previous cadence with `--poll=1000`.
- Implement a poll-driven update path so the console formatter can “tick” even when no new TAP output arrives.
  - Use timeout-aware polling in multiplexer/iterator loops and a formatter tick hook.
- While waiting for TAP progress in interactive mode, render a spinner that advances one frame per poll tick.
  - UTF spinner frames (Codex-style): `⠇`, `⠋`, `⠙`, `⠸`, `⢰`, `⣠`, `⣄`, `⡆` (repeat).
  - ASCII fallback for `--noutf`: `|`, `/`, `-`, `\` (repeat).
- If colorization is enabled, render the spinner in the same muted grey used for labels/dot leaders.

### 3) Millisecond Time Reporting Everywhere
- All wallclock and CPU time displays switch to millisecond units by default (interactive and non-interactive).
- Update `TAP::Formatter::Session::time_report` to emit `Nms` for wallclock and CPU segments regardless of `Time::HiRes` availability.
- Replace `Benchmark::timestr` summary formatting with a millisecond-aware formatter for the summary line:
  - Format: `Files=..., Tests=..., 5000ms wallclock (10ms usr + 10ms sys = 20ms CPU)`
  - Remove the `secs` label; `wallclock` is sufficient because units are shown on values.
- Rounding rules:
  - Round to the nearest millisecond.
  - Use `<1ms` for non-zero durations under 1ms.
  - Use `0ms` only for true zero durations.

### 4) Vitest-Style Colorization and Emphasis
- When color output is enabled, emulate vitest’s TTY palette and emphasis:
  - Labels such as `Files=`, `Tests=`, `wallclock`, `usr`, `sys`, `CPU`, and dot leaders (`..`) are muted grey (vitest uses `tinyrainbow` `c.gray`/`c.dim`).
  - Key values (file/test counts, test names, subtest names) are white (non-dim).
  - Success/failure glyphs: `✓` in green and `×` in red (match existing success/failure coloring).
  - Millisecond numbers use bright amber; the `ms` suffix uses dark amber.
    - In vitest, this effect is achieved by applying `c.yellow` to the full token and `c.dim('ms')` inside it, producing bright yellow digits with dim yellow suffix.
- Add color segmentation helpers so summary/progress lines can colorize sub-spans without affecting non-color output.

### 5) CLI, Documentation, and Test Coverage
- Update CLI help and POD:
  - Document `--poll` and `--noutf` in `App::Prove` POD and `bin/prove` usage.
  - Update example output in POD (e.g., `TAP::Harness::Beyond.pod`) to show ms units and new summary format.
- Add/extend tests under `t/` to cover:
  - `--poll` parsing/validation and defaulting behavior (100ms interactive, 1000ms when explicitly set).
  - UTF status symbols vs `--noutf` fallback.
  - Spinner output cadence in interactive mode (with TTY simulation).
  - Summary line formatting with ms units and `<1ms` handling.
  - Color segmentation when color output is enabled (labels grey, values white, durations amber).
- Ensure non-TTY output remains byte-for-byte compatible with current output (except time unit changes where specified).

## Resolved Decisions (from prior open questions)
- Codex UTF spinner frames: `⠇`, `⠋`, `⠙`, `⠸`, `⢰`, `⣠`, `⣄`, `⡆`.
- Vitest duration color: `tinyrainbow` yellow for digits with `dim` applied to the `ms` suffix (bright amber + dark amber).
- Summary label text: use `wallclock` (drop `secs`).
- Sub-millisecond display: `<1ms` for non-zero durations, rounded to nearest ms.
- `--poll` is CLI-only; no environment variable or HARNESS_OPTIONS support.
