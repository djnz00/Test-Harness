## Summary
Goal: add a configurable output width for `prove` so dots and trailers right-align at a consistent column, with sensible defaults that preserve current behavior when output is non-TTY. This includes a new `--width=N` option, terminal-width defaults for TTY output, a minimum width of 28, and truncation rules for long names.

What IS -> WILL BE:
- IS: Dot padding is based only on the longest top-level test name (`_longest`), so sub-test trailers like `not ok` or `2/5` do not align and there is no width override.
- WILL BE: Dot padding uses a computed `width` (TTY columns or computed default), reserving space for the longest trailer; trailers align vertically unless the width is too small.
- IS: No CLI option to control line width.
- WILL BE: `prove --width=N` overrides computed defaults and clamps to a minimum of 28.
- IS: Top-level names are never truncated; subtest names align only by longest-seen per depth.
- WILL BE: Top-level names may be truncated only in TTY output or when `--width` is set; subtest names may always be truncated; minimum truncated length is 8 characters.

## Architecture Documentation
New or changed components
- `App::Prove` command-line parsing gains `--width=N`, plumbed into harness/formatter args.
- `TAP::Harness` accepts `width` as a formatter arg and passes it into formatter construction.
- `TAP::Formatter::Base` gains width resolution helpers and stores an effective width for formatting.
- `TAP::Formatter::Console` and `TAP::Formatter::File` switch dot padding from `_longest`-based to width-based padding with trailer reservation and truncation rules.
- `TAP::Formatter::Console::Session` and `ParallelSession` continue to render segments, but use updated formatter helpers for dots/truncation.

New or changed interfaces
- CLI: `prove --width=N`.
- Formatter args: `width` (user-specified), `_effective_width` (resolved), and helpers like `_max_trailer_len`, `_dot_padding`, `_truncate_name`.

New or changed data flows
- CLI `--width` -> `App::Prove` -> harness args -> formatter construction -> console/file formatter -> per-line dot computation and truncation.

New or changed event-driven or timer processing
- None. Spinner and polling behavior stays the same; only the line composition changes.

New or changed network programming
- None.

New or changed data stores
- None.

## Detailed Design and Implementation Plan

### Phase 1: CLI and harness plumbing
- Add `--width=N` to `App::Prove::process_args` with validation (integer, allow 0+, clamp later).
- Persist `width` into `App::Prove::_get_args` and pass through to `TAP::Harness` formatter args.
- Update `TAP::Harness` formatter arg list to include `width` so it is passed into formatter construction.
- Update `bin/prove` POD options to document `--width` semantics and minimum width.
- Note: No behavior change until formatter logic is updated.

### Phase 2: Width resolution & shared helpers
- Add `width` validation to `TAP::Formatter::Base` (similar to `poll`/`utf`). Store user-specified width on the formatter.
- Add helper methods in `TAP::Formatter::Base`:
  - `_effective_width(@tests)` or `_resolve_width(@tests)` to compute the width:
    - If user width provided: `max(28, width)`.
    - Else if interactive (TTY): try terminal columns; if unavailable, fall back to non-TTY default.
    - Else (non-TTY): `max(28, longest_top_level + min_dots + max_trailer_len)`.
  - `_terminal_columns` that attempts `Term::ReadKey::GetTerminalSize`, `Term::Size::chars`, or `Term::Table::Util::term_size` under `eval`, then `$ENV{COLUMNS}`; return undef if none.
  - `_max_trailer_len($mode)` returning the longest trailer length for the current output mode:
    - Non-expanded: reserve space for ` not ok` (plus leading space if used).
    - Expanded (`-x`): reserve space for ` MMMM/NNNN not ok` (17 chars in non-UTF; adjust for UTF if needed).
  - `_dot_count($header_len, $trailer_len)` implementing `max(3, width - header_len - trailer_len)`.
  - `_truncate_name($name, $available)` to enforce minimum 8 chars.
- Update `prepare` to compute `_longest` (for summary alignment) and store an effective width when possible.
- Ensure width resolution is also done lazily when `prepare` is not called (iterator-driven tests): compute width on first header render using observed name length and a fallback trailer length.

### Phase 3: Apply width/trailer-aware dot padding and truncation
- Update `TAP::Formatter::Console::_name_segments` to use width-based dots:
  - Compute header length = optional timer prefix + indent (0) + name length + 1 trailing space.
  - Compute trailer length based on mode (expand, utf).
  - Apply truncation only if interactive or user width was set.
  - Build segments: timer prefix (if any), truncated name, single space, dot padding, single space (or leading space in trailer), then trailer rendered by session.
- Update `TAP::Formatter::Console::_subtest_name_data` to use width-based dots and truncation:
  - Indent = `2 * depth` spaces, header = indent + name + single space.
  - Always allow truncation for subtests; enforce minimum 8 chars.
  - Use trailer reservation based on expand mode.
- Update `TAP::Formatter::Base::_format_name` (used by file formatter) to use the same dot/truncation helper logic (no color segments), ensuring non-TTY defaults preserve current behavior.
- Ensure the dot padding is stable for both progress lines (counts) and final status lines so trailers align.
- Verify `TAP::Formatter::Console::ParallelSession` uses the updated subtest helper; decide whether to keep `WIDTH` constant for the ruler or optionally apply formatter width (see Open Questions).

### Phase 4: Tests and documentation
- Add/adjust tests to cover width defaults, overrides, and truncation rules (see Detailed Test Plan).
- Update POD in `bin/prove` and, if needed, `lib/App/Prove.pm` to document `--width` and minimum width behavior.
- Audit any tests that assert exact dot counts or header tokens (notably `t/harness.t`) and update expected output for new alignment.

## Code References to Impacted Code
- `lib/App/Prove.pm:198` - add `--width` option parsing in `GetOptions`.
- `lib/App/Prove.pm:310` - pass `width` through `_get_args` into harness/formatter args.
- `lib/TAP/Harness.pm:60` - extend `@FORMATTER_ARGS` to include `width`.
- `lib/TAP/Harness.pm:462` - formatter argument passing in `_initialize`.
- `lib/TAP/Formatter/Base.pm:231` - `prepare` currently sets `_longest`; add width resolution.
- `lib/TAP/Formatter/Base.pm:245` - `_format_name` uses `_longest`; switch to width-based dots/truncation.
- `lib/TAP/Formatter/Base.pm:282` - `_is_interactive` used to decide default width behavior.
- `lib/TAP/Formatter/Console.pm:315` - `_name_segments` current dot padding; update to width-based dot/trailer logic.
- `lib/TAP/Formatter/Console.pm:331` - `_subtest_name_data` uses longest-per-depth; update to width/truncation logic.
- `lib/TAP/Formatter/Console/Session.pm:84` - uses `_name_segments`; ensure alignment with updated segments.
- `lib/TAP/Formatter/Console/ParallelSession.pm:159` - `_expand_subtest` uses `_subtest_name_data` and should inherit new width behavior.
- `bin/prove:26` - update CLI option documentation to include `--width`.
- `t/harness.t:888` - header token tests depend on `_name_segments` output; update expected tokens.
- `t/expand-subtests.t:17` - integration tests for expanded subtests; extend to assert width alignment and truncation behavior.

## Detailed Test Plan
- New unit test: `t/formatter-width.t` (or similar)
  - Validate `_effective_width` default for non-TTY (using a formatter with fixed `_longest` and `expand` flags).
  - Validate `--width` override clamps to 28.
  - Validate TTY default uses terminal width when available (mock `_terminal_columns` or `_is_interactive`).
- Update `t/harness.t` expected header tokens to match new dot counts and alignment.
- Extend `t/expand-subtests.t`:
  - Add a run with `--width=36` and assert alignment of `2/5` vs `not ok` in expanded output.
  - Add a run with long subtest names to ensure truncation to >= 8 chars.
- New integration test: `t/prove-width.t`
  - Run `prove --width=28` against a sample with long test names and verify dots and trailer alignment.
  - Run `prove` without `--width` in non-TTY mode and verify behavior matches previous alignment (no truncation of top-level names).
- Consider adding fixtures under `t/sample-tests` with long names to exercise truncation edge cases and wrapping.

## Options and Open Questions
- Should `TAP::Formatter::Console::ParallelSession`’s ruler width (`WIDTH => 72`) respect the new width setting or remain fixed for historical behavior?
  Answer: respect the new width setting; legacy width-related code should be removed
- For UTF output, should trailer length be computed with display width (`wcwidth`) instead of `length` to avoid misalignment with wide glyphs?
  Answer: wide glyphs are not used by `prove`, although they might be present in test/subtest names
- If `prepare` is not called (iterator-driven tests), should width be recomputed per test (potentially changing alignment mid-run) or fixed once at first header?
  Answer: width should be recomputed if output is not to a tty and it was not specified with `--width=N`, and it should only be enlarged
- For non-expanded output, should the “longest possible trailer” be only `not ok`, or should it also consider max-length counts from `show_count`?
  Answer: the longest possible trailer is ` MMMM/NNNN not ok`, i.e. it includes the counts up to 9999, beyond which the line can wrap the width
- Should we add a small optional dependency on a terminal-size module, or stick to best-effort `eval` usage with fallbacks only?
  Answer: DO NOT USE eval - there are well-established mechanisms for obtaining console terminal width (ioctl with fallback to env var) - use the perl module most commonly used for this purpose and add this as a dependency
