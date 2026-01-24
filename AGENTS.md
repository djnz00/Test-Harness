# Repository Guidelines

## Project Structure & Module Organization
- `lib/` contains the Perl modules (TAP::* and Test::Harness) with inline POD.
- `bin/prove` is the CLI entry point installed by MakeMaker.
- `t/` holds the core test suite, with helpers in `t/lib` and fixtures in `t/sample-tests`.
- `t/compat/` contains compatibility tests for older behaviors.
- `xt/` is for author/extra tests (optional for contributors).
- `examples/` provides runnable harness examples.
- `reference/` includes a historical Test-Harness snapshot used for comparisons.
- `blib/` and `pm_to_blib/` are build artifacts; do not edit by hand.

## Build, Test, and Development Commands
- `perl Makefile.PL` generates the Makefile (ExtUtils::MakeMaker).
- `make` builds into `blib/`.
- `make test` runs `t/*.t` and `t/compat/*.t`.
- `make testprove` runs tests via the local `bin/prove` (`prove -b -r t`).
- `make testauthor` runs `xt/` tests.
- `make testleaks` runs leak checks (requires `Devel::Leak::Object`).
- `make testreference` compares against `reference/Test-Harness-2.64`.
- `make critic` runs perlcritic using `perlcriticrc`.
- `make tidy` formats with perltidy using `.perltidyrc`.

## Coding Style & Naming Conventions
- Perltidy is the canonical formatter: 4-space indent, 78-char lines, no hard tabs.
- Follow `.perltidyrc` and `perlcriticrc`; run `make tidy` and `make critic` before submitting.
- Prefer subclassing `TAP::Object` for new TAP::* classes.
- Raise exceptions with `Carp::croak`/`Carp::confess`.

## Testing Guidelines
- New tests should be `.t` files under `t/` (or `xt/` for author-only coverage).
- Use `prove -b -r t` for quick local runs; add fixtures under `t/sample-tests`.

## Documentation & POD
- Public docs live in `lib/*.pm` and `lib/*.pod`.
- Use `=head1` with ALL-CAPS section titles; avoid `=head3`/`=head4`.

## Commit & Pull Request Guidelines
- Recent commits use short, imperative summaries (e.g., "fix ...", "Bump ...", "Merge branch ..."). Keep subject lines concise.
- No formal PR template is present; include a brief rationale, tests run (commands + results), and any doc or behavior changes. Add screenshots only if output formatting changes.
