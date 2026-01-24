improve colorization, polling interval and time reporting from `prove`

current output:

```
Files=1, Tests=5,  5 wallclock secs ( 0.01 usr +  0.01 sys =  0.02 CPU)
Result: PASS
```

revised output:

```
Files=1, Tests=5,  5000ms wallclock secs ( 10ms usr + 10ms sys =  20ms CPU)
Result: PASS
```

specific requirements:
- when running interactively in a console, `ok` is replaced with `✓` (green) and failed with `×` (red) (like vitest)
  - this can be reverted to `ok` and the existing failure message with a command line option --noutf
- add a new CLI option to `prove` to specify the polling interval in milliseconds, --poll=N
- when running interactively in a console, default polling interval is reduced from 1 second to 100 milliseconds
  - previous polling interval can be reverted with --poll=1000
- when running interactively in a console, while waiting for TAP output to progress, a spinner character is displayed that advances with each poll
  - use the same spinner characters as openai's codex in order to mimic it
  - if --noutf is in effect (see below), use this sequence: `|`, `/`, `-`, `\`, `|`, `/`, `-`, `\`
- default units are changed to milliseconds from seconds
- when colorization is enabled:
  - enhance colorization to mimic the colors used by `vitest`
  - specific enhancements:
    - `Files=`, `, Tests=`, etc. are in grey text, consistent with colorization used by vitest
    - key values stand out
      - `1`, `5`, in the example output should be in regular white
      - test names and subtest names should be in white
      - `..` etc. should be in grey
    - the millisecond numbers `5000`, `10`, etc. are in bright amber (research javascript's vitest and match the color vitest uses)
      - the `ms` suffix is in dark amber
