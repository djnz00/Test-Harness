## Summary
The goal is to modernize `prove`'s interactive console output: use millisecond time units, add vitest-style glyphs and coloring, and introduce a tighter polling loop with a Codex-like spinner for progress feedback.
High-level requirements include new CLI controls for UTF output and polling cadence, updated formatter behavior for time reporting and color segmentation, and expanded tests/docs to preserve backward-compatible non-TTY output.

## Product Requirements

### Interactive UTF Status Symbols
- Description of the requirement
  - When running interactively on a TTY, replace `ok` with `✓` (green) and failures with `×` (red) to mirror vitest-style status symbols.
- Description of what will be added, modified or removed
  - Add a new `--noutf` CLI option to disable UTF output; when set, fall back to the current `ok`/`not ok` output and existing failure text.
  - Apply the UTF status symbols consistently in per-test completion lines and subtest expanded output (where currently `ok`/`not ok` are emitted).
  - Gate UTF output to interactive console sessions only; non-TTY output remains unchanged.
- How it connects to other requirements
  - This requirement controls the spinner glyph set in the polling requirement and ties into the colorization requirement for success/failure coloring.

### Polling Interval and Spinner Feedback
- Description of the requirement
  - Introduce a poll-driven progress update loop for interactive console output that updates at a configurable interval and advances a spinner while waiting for TAP output to progress.
- Description of what will be added, modified or removed
  - Add `--poll=N` (milliseconds) to `prove` CLI, validate positive integers, and propagate the value through `App::Prove` into formatter/session configuration.
  - Default interactive polling interval becomes 100ms; `--poll=1000` restores the previous 1s cadence.
  - Implement a non-blocking/timeout-aware polling path so the console formatter can update the spinner even when no new TAP results are available (e.g., by adding a poll timeout in multiplexer/iterator loops and a formatter “tick” path).
  - Display a spinner character on the progress line during waits, advancing one frame per poll tick. Use the same Unicode spinner sequence as Codex; if `--noutf` is set, use `| / - \\` repeating.
- How it connects to other requirements
  - Relies on the UTF toggle to choose spinner frames and on the colorization requirement to style the spinner when color output is enabled.

### Millisecond Time Reporting Everywhere
- Description of the requirement
  - All wallclock and CPU time displays switch to millisecond units by default (both per-test and summary). This aligns with modern test runner output that shows ms-level durations.
- Description of what will be added, modified or removed
  - Update `TAP::Formatter::Session::time_report` to emit `Nms` for wallclock and CPU segments, regardless of Time::HiRes availability.
  - Replace `Benchmark::timestr`-based summary formatting with a millisecond-aware formatter for `Files=..., Tests=..., ... wallclock ... ( ... usr + ... sys = ... CPU)`.
  - Ensure very small times are rendered consistently (e.g., `0ms` or `<1ms`) and document the rounding strategy.
- How it connects to other requirements
  - Supplies the “ms” tokens that the colorization requirement highlights in amber, and pairs with the polling change that already treats intervals in milliseconds.

### Vitest-Style Colorization and Emphasis
- Description of the requirement
  - When color output is enabled, console formatting should emulate vitest-style emphasis and symbol coloring, including muted labels and highlighted values.
- Description of what will be added, modified or removed
  - Apply muted grey to labels like `Files=`, `Tests=`, `wallclock`, `usr`, `sys`, `CPU`, and the dot leaders (`..`).
  - Render key values (file/test counts, test names, subtest names) in white, with `✓` in green and `×` in red.
  - Render millisecond numbers (e.g., `5000`, `10`) in bright amber and the `ms` suffix in a darker amber; use ANSI color tokens that best match vitest’s palette (via Term::ANSIColor mappings).
  - Implement color segmentation helpers so summary lines and progress/status lines can colorize sub-spans without changing non-color output.
- How it connects to other requirements
  - Depends on the ms time formatting requirement to identify numeric segments, and the UTF symbol requirement for success/failure glyph coloring.

### CLI, Documentation, and Test Coverage
- Description of the requirement
  - Keep CLI help, POD, and tests synchronized with the new output behavior to avoid regressions.
- Description of what will be added, modified or removed
  - Document `--poll` and `--noutf` in `App::Prove` POD and `bin/prove` usage text; update any example output in POD (e.g., `TAP::Harness::Beyond.pod`) to ms units.
  - Add/extend tests in `t/` to cover:
    - `--poll` parsing/validation and defaulting.
    - UTF status symbols vs `--noutf` fallback.
    - Spinner output cadence in interactive mode (TTY simulation).
    - Summary line formatting and color segmentation in color-enabled mode.
- How it connects to other requirements
  - Validates the behavior specified in requirements 1–4 and preserves backwards compatibility for non-interactive output.

## Options and Open Questions
- What are the exact Unicode spinner frames used by the current Codex CLI/TUI? (Need to confirm from Codex source to match precisely.)
  Answer: `⠇`, `⠋`, `⠙`, `⠸`, `⢰`, `⣠`, `⣄`, `⡆`
- Which ANSI color tokens best match vitest’s amber duration color? (Confirm against vitest reporter implementation/palette.)
  Answer: inspect the vitest source code in `../vitest` to determine this
- Should the label text change from `wallclock secs` to `wallclock ms`, or should only the numeric units change while keeping the legacy label (as in the example)?
  Answer: change the label to `wallclock`, the `secs` is redundant and confusing because the preceding number will have `ms` units suffixed
- How should sub-millisecond durations be displayed (`0ms` vs `<1ms`) and rounded (floor vs nearest)?
  Answer: `<1ms` for non-zero, and rounded
- Should `--poll` be exposed via environment variables or `HARNESS_OPTIONS`, or stay CLI-only?
  Answer: CLI-only
