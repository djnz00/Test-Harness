## Summary
Goal: introduce a configurable output width for `prove` so trailers (status and expanded subtest counts) align to a consistent column, while preserving existing non-TTY behavior when `--width` is not specified. This requires a new `--width=N` CLI option, a minimum width of 28, terminal-width defaults for TTY output, trailer-aware dot padding, and name truncation rules.

Requirements feasibility & complexity (all feasible with current Perl/TAP stack):
- Width defaults (TTY columns; non-TTY derived from longest top-level name + min dots + max trailer; min 28): **low complexity**. Requires a terminal-size dependency and formatter-level width resolution.
- Width override via `--width=N` with clamping to 28: **low complexity**. Straightforward CLI plumbing and formatter arg validation.
- Dot padding with trailer reservation + minimum 3 dots: **moderate complexity**. Touches console/file formatters, progress lines, and expanded subtest formatting.
- Truncation rules (top-level only when TTY or `--width`; subtests always; min 8 chars): **moderate complexity**. Needs shared truncation helper and test updates.

High-level design: add a `width` formatter argument via `App::Prove` and `TAP::Harness`, introduce width resolution and helper methods in `TAP::Formatter::Base`, switch `TAP::Formatter::Console` and `TAP::Formatter::File` dot padding to width/trailer-aware calculation, adjust parallel ruler width to follow the formatter width, and add tests/fixtures for alignment and truncation behavior.

## Architecture Documentation
New or changed components
- `App::Prove` parses `--width=N` and passes it to `TAP::Harness`.
- `TAP::Harness` forwards `width` to formatter construction (`TAP::Formatter::Console`/`File`).
- `TAP::Formatter::Base` resolves effective width and provides shared helpers for trailer length, dot padding, and truncation.
- `TAP::Formatter::Console` and `TAP::Formatter::File` use width-based dot/trailer logic for top-level and subtest lines.
- `TAP::Formatter::Console::ParallelSession` ruler width aligns to formatter width.
- New dependency: `Term::ReadKey` for terminal size detection.

New or changed processes or threads
- None.

New or changed interfaces
- CLI: `prove --width=N`.
- Formatter args: `width` (user-specified), `_effective_width` (resolved internally), new helper methods for width/trailer computation.

New or changed data flows
- CLI `--width` -> `App::Prove` -> `TAP::Harness` -> formatter -> `_effective_width` -> dot/truncation helpers used by console/file output.

New or changed event-driven or timer processing
- None.

New or changed network programming
- None.

New or changed data stores
- Distribution metadata: add `Term::ReadKey` to `PREREQ_PM` (Makefile.PL) so terminal size can be determined without `eval` fallback.

API scrutiny for new dependency (Term::ReadKey)
- `Term::ReadKey::GetTerminalSize([HANDLE])` returns an empty list if unsupported, or `(cols, rows, xpix, ypix)`.
- On Windows, `GetTerminalSize` **must** be called with an output handle (e.g., `\*STDOUT`).
- The module is already available locally, but must be added as a declared dependency for consistent behavior.

## Detailed Design and Implementation Plan

### Phase 1: CLI and harness plumbing
- Add `width` to `App::Prove` attributes and parse `--width=N` via `Getopt::Long`.
  - Validate numeric integer; allow `0` or positive values and defer clamping to formatter (non-numeric -> `croak`).
- Pass `width` through `_get_args` so it reaches `TAP::Harness`.
- Add `width` to `TAP::Harness` `@FORMATTER_ARGS` so it is forwarded into formatter construction.
- Update `bin/prove` POD options to describe `--width`, the TTY default, and the minimum width of 28.
- Update `lib/App/Prove.pm` POD (options list) to document `--width` and its interaction with TTY/non-TTY defaults.

### Phase 2: Width resolution and shared helpers in `TAP::Formatter::Base`
- Add a `width` validation entry in `%VALIDATION_FOR` and accessors for:
  - `width` (user-specified), `_effective_width` (resolved width), and `_width_source` (optional, for debugging/testing).
- Add terminal-width resolution helper `_terminal_columns`:
  - Call `Term::ReadKey::GetTerminalSize($self->stdout)` and return the `cols` value when available.
  - If `GetTerminalSize` returns empty list or `cols` is undefined, try `$ENV{COLUMNS}` if numeric.
  - If still unavailable, return `undef`.
- Add trailer and dot helpers (shared across formatters):
  - `_min_width` constant = 28.
  - `_max_trailer_len($context)` returning the **maximum** trailer length for the current output mode.
    - For expanded subtests: reserve ` MMMM/NNNN not ok` (17 chars) when `utf` is off; if `utf` is on, reserve ` MMMM/NNNN` + 1 status glyph.
    - For non-expanded top-level lines: reserve max of `not ok` length and the maximum count token (`MMMM/NNNN` + leading space, if counts are shown).
  - `_dot_count($header_len, $trailer_len)` returns `max(3, _effective_width - header_len - trailer_len)`.
  - `_truncate_name($name, $max_len)` truncates only when `max_len >= 8`; otherwise returns original.
- Width resolution logic `_resolve_width(@tests)`:
  - If `width` provided: `_effective_width = max(28, width)`.
  - Else if interactive: use `_terminal_columns` and clamp to 28; if no terminal width, fall back to non-TTY default.
  - Else (non-TTY default): `_effective_width = max(28, longest_top_level + 3 + max_trailer_len)`.
- Pseudocode reference for width + dots/truncation math:
  ```perl
  # width resolution
  if (defined $width) { $effective = max(28, $width) }
  elsif ($interactive && $cols) { $effective = max(28, $cols) }
  else { $effective = max(28, $longest + 3 + $max_trailer_len) }

  # per-line formatting
  $dots = max(3, $effective - $header_len - $trailer_len);
  $available_name = $effective - $trailer_len - 3 - $header_prefix_len;
  $name = truncate($name, $available_name) if $allow_truncate;
  ```
- Update `prepare(@tests)` to:
  - Preserve `_longest` for existing summary behavior.
  - Compute `_effective_width` using `_resolve_width(@tests)` when tests are known.
- Lazy width handling for iterator-driven runs (when `prepare` is not called):
  - On first top-level header render, if `width` is not set and output is non-TTY, compute `_effective_width` based on the longest name seen so far; allow it to **grow** on later tests if a longer name appears.
  - Keep `_effective_width` fixed when `width` is set or when output is TTY (terminal columns should not drift).

### Phase 3: Apply width/trailer-aware padding and truncation
- `TAP::Formatter::Console::_name_segments`:
  - Use formatter helpers to compute effective width, trailer length, and dot count.
  - Include timer prefix length (when enabled) in header length.
  - Apply top-level truncation only when interactive or `width` is explicitly set.
- `TAP::Formatter::Console::_subtest_name_data`:
  - Drop `longest` tracking (no longer needed for width-based alignment).
  - Compute indent (`2 * depth`) + name + space as header; reserve trailer length using expand mode.
  - Always allow truncation for subtests (min 8 chars).
- `TAP::Formatter::Base::_format_name` (used by `TAP::Formatter::File`):
  - Replace `_longest`-based dots with width/trailer-aware dots and truncation rules.
  - Ensure non-TTY default still uses computed width based on longest top-level name when `--width` is not specified.
- `TAP::Formatter::Console::ParallelSession` ruler:
  - Replace `WIDTH => 72` with formatter's `_effective_width` (clamped to 28) so ruler aligns with new width behavior.
  - Keep existing truncation logic for the ruler tail (`... )===`) but base its chop length on the resolved width.
- Ensure dot padding is stable for both progress lines (counts) and final status lines by reserving the maximum trailer length for the current output mode.

### Phase 4: Tests, fixtures, and documentation updates
- New test file: `t/formatter-width.t` (unit-style) to validate `_resolve_width`:
  - Non-TTY default uses `longest_top_level + 3 + max_trailer_len` and clamps to 28.
  - TTY default uses terminal width; mock `_terminal_columns`.
  - `--width` override clamps to 28 even when smaller.
- Update `t/harness.t` expected header tokens to match new dot counts/truncation logic.
- Extend `t/expand-subtests.t`:
  - Add `--width=36` run with expanded subtests and assert aligned trailers (`2/5 not ok` vs `ok`/`UTF ok`).
  - Add a long subtest name to confirm truncation to >= 8 chars.
- Add fixtures under `t/sample-tests/` for long top-level and subtest names to exercise truncation and wrapping.
- Update `bin/prove` and `lib/App/Prove.pm` POD to include `--width` semantics and the minimum width behavior.

## Code References to Impacted Code
- `lib/App/Prove.pm:24` - add `width` to attribute list.
- `lib/App/Prove.pm:182` - parse `--width` in `GetOptions`.
- `lib/App/Prove.pm:310` - pass `width` through `_get_args` to formatter args.
- `lib/TAP/Harness.pm:55` - add `width` to `@FORMATTER_ARGS`.
- `lib/TAP/Formatter/Base.pm:13` - add validation/accessors for `width` and `_effective_width`.
- `lib/TAP/Formatter/Base.pm:222` - update `prepare` to compute `_effective_width`.
- `lib/TAP/Formatter/Base.pm:245` - update `_format_name` to use width/trailer-aware dots and truncation.
- `lib/TAP/Formatter/Console.pm:315` - update `_name_segments` for width/trailer-aware padding.
- `lib/TAP/Formatter/Console.pm:331` - update `_subtest_name_data` to width-based padding.
- `lib/TAP/Formatter/Console/ParallelSession.pm:14` - replace `WIDTH` constant with formatter width; remove `WIDTH` and referencing code.
- `lib/TAP/Formatter/Console/ParallelSession.pm:69` - update ruler chop/pad behavior based on effective width.
- `bin/prove:32` - document `--width`.
- `Makefile.PL:18` - add `Term::ReadKey` to `PREREQ_PM`.
- `t/harness.t:120` - update header token expectations.
- `t/expand-subtests.t:30` - add width/truncation assertions.
- `t/formatter-width.t` - new tests for width resolution.
- `t/sample-tests/` - new fixtures for long names.

## Detailed Test Plan
- `t/formatter-width.t`:
  - Create a formatter with `HARNESS_NOTTY=1`, set `_longest`, and verify `_effective_width` matches `max(28, longest + 3 + trailer_len)`.
  - Mock `_terminal_columns` to return a fixed width and verify TTY default uses it (clamped to 28).
  - Verify `--width=10` resolves to 28.
- `t/harness.t`:
  - Update expected header token sequences to account for new dot padding.
- `t/expand-subtests.t`:
  - Run `prove -x --width=36` and assert top-level + subtest trailers align.
  - Add a long subtest name and verify truncation is >= 8 chars.
- New fixture tests under `t/sample-tests`:
  - Long top-level test names to verify truncation rules under `--width` and TTY vs non-TTY defaults.

## Options and Open Questions
Options considered and decisions
- Terminal width detection: **Use `Term::ReadKey::GetTerminalSize`** (no `eval` fallbacks) with `$ENV{COLUMNS}` as a last-resort numeric hint; fall back to non-TTY default if no width is available.
- Parallel ruler width: **Respect formatter width** instead of the fixed `WIDTH => 72` constant.
- UTF output: **Use status token length for trailer reservation**, but keep non-UTF maximum (17 chars) for expanded subtests when `utf` is disabled.

Open questions
- None.
