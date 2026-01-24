# Code Review: modernize console output vs META.arc/modernize/plan.new.md

## Scope
Reviewed the pending changes on branch `modernize-colors` against `META.arc/modernize/plan.new.md`, focusing on:
- CLI plumbing + formatter args (`bin/prove`, `lib/App/Prove.pm`, `lib/TAP/Harness.pm`)
- Polling/tick (`lib/TAP/Parser/Multiplexer.pm`, `lib/TAP/Harness.pm`)
- MS timing (`lib/TAP/Base.pm`, `lib/TAP/Formatter/Base.pm`, `lib/TAP/Formatter/Session.pm`, `lib/TAP/Parser/Aggregator.pm`)
- Console output/segments/spinner (`lib/TAP/Formatter/Console.pm`, `lib/TAP/Formatter/Console/Session.pm`, `lib/TAP/Formatter/Console/ParallelSession.pm`)
- Tests (`t/harness.t`, `t/file.t`, `t/prove.t`, `t/console-spinner.t`, `t/time-report-ms.t`)

## Plan alignment (summary)
- Phase 1 (CLI plumbing): Implemented `--poll` + `--utf/--noutf` plumbing and formatter args; docs updated in `bin/prove` and `App::Prove` POD.
- Phase 2 (polling/tick): Added timeout-aware `Multiplexer->next($timeout)` + `timed_out` flag; Harness loops call `tick()` on timeout.
- Phase 3 (ms timing): Implemented ms-only formatting and summary line rewrite; added `wallclock_elapsed` for higher precision.
- Phase 4 (UTF + colors): Implemented UTF tokens, spinner frames, segment rendering, palette helpers, and cursor hide/show.
- Phase 5 (tests/docs): Added new tests and updated existing regex expectations.

## Findings (ordered by severity)

1) Medium — PTY tests don’t skip when PTY allocation fails despite IO::Pty being installed.
- File: `t/console-spinner.t:81-85`
- Risk: On systems with IO::Pty installed but /dev/ptmx not available (CI containers), the test dies instead of skipping, producing noisy failures (this already happened once in this repo’s run history).
- Recommendation: Add a runtime guard: if `IO::Pty->new` or `$pty->slave` fails, or `-t $tty` is false, call `plan skip_all` or `skip` for the affected assertions.
  ACTION: ADOPT recommendation

2) Medium — Timeout error path in `Multiplexer->next($timeout)` can prematurely exit the aggregate loop without surfacing an error.
- File: `lib/TAP/Parser/Multiplexer.pm:141-152`
- Risk: `can_read($timeout)` returning undef with `$!` set causes an immediate `return` with `timed_out` false, and `_aggregate_parallel` simply exits its RESULT block without draining or surfacing the error. This can leave parsers unfinished and still in the mux.
- Recommendation: convert this branch into either (a) an exception (die/croak), (b) a dedicated “error” state for the harness to handle, or (c) set `timed_out = 0` and return a sentinel so the harness can log and bail safely.
  ACTION: ADOPT (c)

3) Low — Console palette helpers hard-code a single path, preventing intended fallbacks.
- Files: `lib/TAP/Formatter/Console.pm:197-226`
- Issue: `_muted_colors` returns `white+dark` whenever `white` is supported, so `bright_black` is never used. `_ms_digits_color` prefers `yellow` over `bright_yellow` even when the bright variant is supported.
- Impact: Harder to tune output for “modernized” UX; diverges from plan and makes palette changes less predictable.
- Recommendation: Switch the order to prefer `bright_black` (for muted) and `bright_yellow` (digits), then fall back to `white+dark` / `yellow`.
  ACTION: IGNORE this recommendation

4) Low — Colorized progress lines still rely on legacy string formatting for length calculation.
- Files: `lib/TAP/Formatter/Console/Session.pm:83-209`
- Issue: Progress state uses `_format_name()` text length and manually reconstructs the colored line via a separate segment list. This increases risk of drift (e.g., if `_format_name` and `_name_segments` diverge) and complicates maintenance.
- Recommendation: make “segments” the single source of truth and compute lengths from `_segments_text()` only, even when no colorizer is present.
  ACTION: ADOPT this recommendation

## Consolidation / reuse opportunities (proposed, not implemented)

1) Unify spinner rendering and padding logic.
- Current: spinner output is duplicated across `Console::Session` (progress + subtest progress) and `Console::ParallelSession` (ruler). Each has its own pad + color + cursor-hide logic.
- Proposed: move spinner rendering into `TAP::Formatter::Console` helpers (e.g., `_render_spinner($prefix, $spinner, $padlen)`), and centralize cursor hide/show there. This would also allow consistent handling of spinner clearing and reduce the need for `last_len` bookkeeping in multiple places.
  ACTION: ADOPT this proposal

2) Share subtest name formatting between serial and parallel sessions.
- Current: both `Console::Session` and `Console::ParallelSession` construct subtest prefix/dots and segments independently.
- Proposed: extract a shared helper (e.g., in `TAP::Formatter::Console::Subtest`) that returns `{text, segments, len}` for a subtest header. This reduces duplication and makes spacing fixes (like the “space before ..”) centralized.
  ACTION: ADOPT this proposal

3) Replace string re-parsing for time segments with structured data.
- Current: `time_report()` returns a string, then `Console::_time_report_segments()` regex-splits it. Summary does similar: Base builds a string, Console re-splits.
- Proposed: return a structured representation (`[ {kind => 'ms', value => ...}, {kind => 'label', ...} ]`) from `time_report` and a new `summary_runtime_parts`, then render segments directly without regex re-parsing. This reduces string fragility and makes ms precision formatting more robust.
  ACTION: ADOPT this proposal

## Legacy behaviors to consider dropping (with cascading test updates)

1) Stop preserving exact non-TTY ASCII status tokens by default.
- Current: `_status_token` forces ASCII on non-TTY, while UTF glyphs are TTY-only.
- Proposal: make UTF the default everywhere, with `--noutf` as explicit fallback (even on non-TTY). This eliminates `_is_interactive` gating in several places and simplifies segment rendering logic; update tests in `t/file.t` and `t/harness.t` accordingly.
  ACTION: ADOPT this proposal

2) Replace “legacy string capture” in `t/harness.t` with segment-aware assertions.
- Current: helpers like `header_tokens()`, `pop_status_line()`, and `split_summary()` exist to preserve pre-modernized expectations.
- Proposal: assert against structured sequences (color token + text) rather than reassembling old strings. This would remove brittle trimming logic and reduce test maintenance when colors evolve.
  ACTION: ADOPT this proposal

3) Consider dropping child CPU times (`cusr/csys`) from per-test `time_report`.
- Rationale: These fields are legacy carry-overs from classic `Harness` output and clutter the line when targeting a “Vitest-like” UI. Dropping them simplifies format, reduces parsing, and matches the modern UX goal. Tests in `t/time-report-ms.t` and any CPU expectations would need updates.
  ACTION: ADOPT this proposal

## Additional proposed cleanup (non-breaking)
- Add a small helper in `App::Prove` to validate and normalize `poll` to an integer during option parsing (rather than post-parse). This consolidates validation and removes the need to delete-and-croak.
- Use a single “interactive” predicate exposed from `TAP::Formatter::Base` so both Console and Session use the same logic.
- Track `_current_session` lifecycle (set to undef on close) to avoid stale references and make it easier to detect “no active session” in `tick()`.
  ACTION: ADOPT these proposals

## Recommended follow-up list (not implemented)
1) Add PTY-allocation guards in `t/console-spinner.t`.
  ACTION: ADOPT this proposal
2) Decide whether to drop non-TTY ASCII defaults; if yes, remove TTY gating and update tests.
  ACTION: ADOPT this proposal
3) Consolidate spinner rendering + subtest formatting to reduce duplicate logic across sessions.
  ACTION: ADOPT this proposal
