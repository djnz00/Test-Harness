## Summary
Research conducted on January 21, 2026. The codebase implements the Test Anything Protocol (TAP) toolchain: a parser, harness, formatters, and the `prove` CLI with persistent state. Core runtime modules live under `lib/` (TAP::* and Test::Harness), with parser iterators, source handlers, and results modeling TAP streams and test outcomes. The repository also includes YAMLish serialization used by `prove` state, a historical reference snapshot of Test-Harness 2.64, example scripts, benchmarks, smoke-test automation scripts, and test helpers under `t/` for exercising subclassing and compatibility paths. (Examples: lib/TAP/Parser.pm:408, lib/TAP/Harness.pm:544, lib/App/Prove.pm:150, lib/TAP/Parser/YAMLish/Reader.pm:34, reference/Test-Harness-2.64/lib/Test/Harness.pm:234, examples/analyze_tests.pl:18, benchmark/by_stage.pl:13, smoke/smoke.pl:204)

## Coding style and conventions
- Perl modules consistently use `use strict;` and `use warnings;`, with `package` declarations at top and `$VERSION` declared near POD. (lib/TAP/Object.pm:1-16, lib/TAP/Formatter/Console.pm:1-19)
- Constructors follow `new` in `TAP::Object` with class-specific `_initialize` overrides; many classes inherit from `TAP::Object` or `TAP::Base` via `use base`. (lib/TAP/Object.pm:52-69, lib/TAP/Base.pm:6, lib/TAP/Formatter/Session.pm:59-83)
- Exceptions are raised through `Carp::croak`/`confess` wrappers in TAP::Object and used throughout. (lib/TAP/Object.pm:84-107)
- Accessors are created with explicit methods or dynamic method generation (e.g., `mk_methods`, `BEGIN` closures, or method tables). (lib/TAP/Object.pm:139-148, lib/TAP/Formatter/Session.pm:10-17, lib/App/Prove/State/Result.pm:101-112)
- Private/internal helpers typically use a leading underscore, and POD uses `=head1`/`=head2` for sections. (lib/TAP/Harness.pm:804-892, lib/TAP/Parser.pm:1379-1532)
- Constants and environment-specific flags are declared with `use constant` where needed. (lib/TAP/Base.pm:21-24, lib/TAP/Formatter/Console/ParallelSession.pm:11)

## Detailed Findings

### Core object model and callbacks
- `TAP::Object` defines the shared constructor, exception helpers, and `mk_methods` utility used across TAP::* classes. (lib/TAP/Object.pm:52-149)
- `TAP::Base` extends `TAP::Object` with callback registration and invocation, plus timing helpers. (lib/TAP/Base.pm:50-131)
- Core classes like `TAP::Harness`, `TAP::Parser`, and `TAP::Formatter::Session` derive from this base structure. (lib/TAP/Harness.pm:428-483, lib/TAP/Parser.pm:408-489, lib/TAP/Formatter/Session.pm:6-83)

### Harness orchestration and environment setup
- `TAP::Harness` initializes defaults for aggregator, formatter, multiplexer, parser, and scheduler classes, and chooses the file formatter when stdout is not a tty. (lib/TAP/Harness.pm:420-476)
- `runtests` builds an aggregator, triggers callbacks, executes tests, and delegates summary output to the formatter. (lib/TAP/Harness.pm:544-595)
- Test aggregation runs either in parallel via `TAP::Parser::Multiplexer` or serially, depending on `jobs`. (lib/TAP/Harness.pm:617-687, lib/TAP/Parser/Multiplexer.pm:82-185)
- `make_parser` creates a parser from job-specific args and opens a formatter session; `finish_parser` closes sessions and manages TAP spooling. (lib/TAP/Harness.pm:804-892)
- `TAP::Harness::Env` parses `HARNESS_*` environment variables and `HARNESS_OPTIONS` to create the harness with appropriate defaults. (lib/TAP/Harness/Env.pm:56-118)

### Formatter pipeline
- `TAP::Formatter::Base` validates formatter args, configures color output, and emits the final summary report based on the aggregator. (lib/TAP/Formatter/Base.pm:78-361)
- `TAP::Formatter::Console` opens a session class (serial or parallel) and applies colorized output. (lib/TAP/Formatter/Console.pm:35-98)
- `TAP::Formatter::Console::Session` builds closures that process results, manage progress output, and emit per-test summaries. (lib/TAP/Formatter/Console/Session.pm:80-206)
- `TAP::Formatter::Console::ParallelSession` shares context across concurrent tests and prints a live ruler for parallel progress. (lib/TAP/Formatter/Console/ParallelSession.pm:15-199)
- `TAP::Formatter::File` and its session buffer results and output them per-test, preventing interleaving in parallel runs. (lib/TAP/Formatter/File.pm:37-50, lib/TAP/Formatter/File/Session.pm:36-92)
- `TAP::Formatter::Session` provides session initialization, failure reporting, and timing summaries used by concrete session classes. (lib/TAP/Formatter/Session.pm:59-215)

### TAP parser pipeline and result modeling
- `TAP::Parser` converts `source`, `tap`, `exec`, or `iterator` inputs into a `TAP::Parser::Iterator` via `TAP::Parser::Source` and `TAP::Parser::IteratorFactory`. (lib/TAP/Parser.pm:408-489, lib/TAP/Parser/Source.pm:229-307, lib/TAP/Parser/IteratorFactory.pm:198-219)
- Parsing is driven by a state machine built by `_make_state_table`, which tracks plans, tests, TODO/skip state, and error conditions. (lib/TAP/Parser.pm:1151-1251)
- `_iter` drives tokenization, applies callbacks, and spools raw TAP if requested; `_finish` finalizes counts and sanity checks. (lib/TAP/Parser.pm:1379-1532)
- `TAP::Parser::Grammar` defines token regexes per TAP version and produces token objects from iterator lines. (lib/TAP/Parser/Grammar.pm:81-313)
- `TAP::Parser::ResultFactory` maps token types to `TAP::Parser::Result::*` classes; base results define `is_*` helpers and stringification, while `Result::Test` implements test-specific status logic. (lib/TAP/Parser/ResultFactory.pm:64-116, lib/TAP/Parser/Result.pm:10-187, lib/TAP/Parser/Result/Test.pm:125-239)
- `TAP::Parser::Aggregator` collects per-test parser results and provides summary counts and status. (lib/TAP/Parser/Aggregator.pm:115-398)
- `TAP::Parser::Scheduler` organizes tests into sequential/parallel schedules via glob rules, yielding `Job` and `Spinner` objects. (lib/TAP/Parser/Scheduler.pm:129-374, lib/TAP/Parser/Scheduler/Job.pm:42-125, lib/TAP/Parser/Scheduler/Spinner.pm:41-53)
- `TAP::Parser::Multiplexer` multiplexes parser outputs across parallel jobs using `IO::Select` where supported. (lib/TAP/Parser/Multiplexer.pm:82-185)
- `TAP::Parser::SourceHandler` defines the abstract interface; concrete handlers (`Perl`, `Executable`, `File`, `RawTAP`, `Handle`) detect sources and create iterators. (lib/TAP/Parser/SourceHandler.pm:68-92, lib/TAP/Parser/SourceHandler/Perl.pm:73-155, lib/TAP/Parser/SourceHandler/Executable.pm:68-130, lib/TAP/Parser/SourceHandler/File.pm:64-101, lib/TAP/Parser/SourceHandler/RawTAP.pm:67-110, lib/TAP/Parser/SourceHandler/Handle.pm:65-104)
- Iterator implementations include process execution, array-backed TAP, and stream-based TAP. (lib/TAP/Parser/Iterator/Process.pm:115-351, lib/TAP/Parser/Iterator/Array.pm:65-85, lib/TAP/Parser/Iterator/Stream.pm:45-101)

### App::Prove CLI and state management
- `App::Prove` parses command-line options, RC files, and builds harness args; it loads plugins/modules and runs tests via `TAP::Harness::Env`. (lib/App/Prove.pm:150-385, lib/App/Prove.pm:476-555)
- `_get_tests` delegates selection to the state manager (including recursion, shuffling, and ordering). (lib/App/Prove.pm:517-533)
- `App::Prove::State` handles `--state` switches, test discovery, and persists state via YAMLish reader/writer. (lib/App/Prove/State.pm:206-522)
- `App::Prove::State::Result` and `Result::Test` encapsulate stored test run metadata and expose getters/setters via method tables. (lib/App/Prove/State/Result.pm:51-177, lib/App/Prove/State/Result/Test.pm:31-150)

### Legacy Test::Harness compatibility layer
- `Test::Harness` provides `runtests` and `execute_tests` API using `TAP::Harness` underneath, aggregating results and formatting legacy failure summaries. (lib/Test/Harness.pm:141-425)
- It maps environment settings to harness arguments and uses callbacks to observe plans and skipped tests. (lib/Test/Harness.pm:125-350)

### YAMLish serialization
- `TAP::Parser::YAMLish::Reader` parses YAMLish with a line-based reader callback, handling scalars, arrays, hashes, and block scalars. (lib/TAP/Parser/YAMLish/Reader.pm:34-315)
- `TAP::Parser::YAMLish::Writer` emits YAMLish for scalars, arrays, and hashes to multiple output types. (lib/TAP/Parser/YAMLish/Writer.pm:31-144)

### Tests, helpers, and fixtures under `t/`
- `t/lib/` provides subclassing helpers for parser, grammar, result factories, and source handlers used in tests. (t/lib/MySourceHandler.pm:3-36, t/lib/MyGrammar.pm:3-16, t/lib/MyResultFactory.pm:3-19, t/lib/MyResult.pm:3-16, t/lib/TAP/Parser/SubclassTest.pm:3-35)
- Additional test utilities include a harness subclass, fork-stubbing utility, null handle, and output capture helper. (t/lib/TAP/Harness/TestSubclass.pm:1-9, t/lib/NoFork.pm:1-8, t/lib/Dev/Null.pm:1-17, t/lib/IO/c55Capture.pm:33-116)
- `t/source_tests/source.pl` emits simple TAP for source handler tests. (t/source_tests/source.pl:1-6)

### Examples, benchmarks, smoke scripts, and reference snapshot
- Examples demonstrate state analysis, harness callbacks, silent harness usage, and parallel test execution patterns. (examples/analyze_tests.pl:18-85, examples/harness-hook/lib/Harness/Hook.pm:11-27, examples/harness-hook/hook.pl:12-18, examples/silent-harness.pl:12-16, examples/bin/forked_tests.pl:24-61)
- Benchmarks run parser/grammar/source stages and compare to `prove`/`runtests` timings. (benchmark/by_stage.pl:13-123, benchmark/parser_only.pl:5-12)
- Smoke scripts automate testing across VCS revisions and generate reporting and stats. (smoke/smoke.pl:204-428, smoke/stats.pl:109-150)
- `reference/Test-Harness-2.64` contains a historical snapshot of the pre-TAP-parser harness for comparison. (reference/Test-Harness-2.64/lib/Test/Harness.pm:234-253, reference/Test-Harness-2.64/lib/Test/Harness/Straps.pm:108-199)

## Code References
- `lib/TAP/Object.pm:52` - Base constructor used by TAP::* classes.
- `lib/TAP/Base.pm:50` - Callback registration and initialization for TAP::Harness/TAP::Parser.
- `lib/TAP/Harness.pm:544` - Harness entry point for running tests with aggregation and callbacks.
- `lib/TAP/Harness.pm:617` - Parallel aggregation loop using multiplexer.
- `lib/TAP/Formatter/Base.pm:278` - Summary reporting based on aggregator results.
- `lib/TAP/Formatter/Console/Session.pm:119` - Result handling and live output logic.
- `lib/TAP/Parser.pm:408` - Parser initialization and input normalization into iterators.
- `lib/TAP/Parser.pm:1151` - Parser state machine construction for TAP tokens.
- `lib/TAP/Parser/Grammar.pm:81` - Token regex definitions for TAP versions.
- `lib/TAP/Parser/IteratorFactory.pm:198` - Iterator construction via source handler detection.
- `lib/TAP/Parser/SourceHandler/Perl.pm:140` - Perl test execution and iterator creation.
- `lib/TAP/Parser/Aggregator.pm:115` - Aggregation of per-test parser results.
- `lib/TAP/Parser/Scheduler.pm:129` - Scheduler rule expansion into parallel/sequence structure.
- `lib/App/Prove.pm:476` - CLI run path and harness invocation.
- `lib/App/Prove/State.pm:444` - Persisting test results into state manager.
- `lib/TAP/Parser/YAMLish/Writer.pm:31` - YAMLish serialization entry point.
- `lib/Test/Harness.pm:141` - Legacy `runtests` wrapper around TAP::Harness.
- `examples/silent-harness.pl:12` - Example of running harness in silent mode.
- `benchmark/by_stage.pl:13` - Benchmark driver for source/grammar/parser stages.
- `smoke/smoke.pl:204` - Smoke-test orchestration across VCS revisions.
- `reference/Test-Harness-2.64/lib/Test/Harness.pm:234` - Legacy runtests implementation in snapshot.

## Architecture Documentation
- **Core object model**: `TAP::Object` provides a standardized constructor (`new` + `_initialize`) and exception helpers; `TAP::Base` adds callback management and timing helpers used by the parser, harness, and formatter sessions. (lib/TAP/Object.pm:52-149, lib/TAP/Base.pm:50-131, lib/TAP/Formatter/Session.pm:59-215)
- **Harness flow**: `TAP::Harness` builds a scheduler and formatter, opens parser sessions per test, and aggregates results. In parallel mode it uses `TAP::Parser::Multiplexer` to read from multiple parsers concurrently. (lib/TAP/Harness.pm:744-892, lib/TAP/Harness.pm:617-687, lib/TAP/Parser/Multiplexer.pm:82-185)
- **Parser pipeline**: `TAP::Parser` converts sources into iterators through `TAP::Parser::Source` and `IteratorFactory`, tokenizes with `TAP::Parser::Grammar`, constructs `Result::*` objects via `ResultFactory`, and updates its internal state machine and summary counters. (lib/TAP/Parser.pm:408-1532, lib/TAP/Parser/Source.pm:229-307, lib/TAP/Parser/IteratorFactory.pm:198-219, lib/TAP/Parser/Grammar.pm:291-313, lib/TAP/Parser/ResultFactory.pm:64-116)
- **Source handling**: Source handlers implement `can_handle` and `make_iterator` to map raw sources (files, handles, exec commands, raw TAP, arrays) into iterator classes (`Process`, `Stream`, `Array`). (lib/TAP/Parser/SourceHandler.pm:68-92, lib/TAP/Parser/SourceHandler/Executable.pm:103-130, lib/TAP/Parser/Iterator/Process.pm:115-351)
- **Formatting and reporting**: Formatter sessions receive parser results per test, format output, and the formatter base summarizes the aggregate after the run. The console formatter selects serial or parallel session classes to match harness concurrency. (lib/TAP/Formatter/Console.pm:35-57, lib/TAP/Formatter/Console/ParallelSession.pm:121-199, lib/TAP/Formatter/Base.pm:278-361)
- **CLI and state persistence**: `App::Prove` composes harness arguments, runs tests via `TAP::Harness::Env`, and uses `App::Prove::State` to persist results in YAMLish format across runs. (lib/App/Prove.pm:287-555, lib/App/Prove/State.pm:481-522, lib/TAP/Parser/YAMLish/Reader.pm:34-63)
- **Reference snapshot**: `reference/Test-Harness-2.64` provides the pre-TAP-parser harness implementation for comparisons, separate from the main runtime stack. (reference/Test-Harness-2.64/lib/Test/Harness.pm:234-253)

## Open Questions
- Benchmark scripts reference `tmassive/huge.t` and `baseline.yaml`, which are not part of `source.yaml`; the source and expected data for these benchmarks are outside the current analysis scope. (benchmark/by_stage.pl:13-15)
- Smoke scripts expect external configuration and status files (e.g., `smoke/smoke.pl` and `smoke/stats.pl` load config paths and persist state), which are not included in `source.yaml`. The exact structure and lifecycle of those configs is not documented here. (smoke/smoke.pl:204-279, smoke/stats.pl:29-43)
