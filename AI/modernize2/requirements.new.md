# Output Width and Right-Alignment for `prove`

## Overview
Define a configurable output `width` used to right-align `prove` output lines (test names, dots, and trailers such as result status and optional subtest counts). This replaces the implicit width derived from the longest test name, while preserving existing behavior when appropriate.

## Scope
This document specifies requirements only. It does not describe implementation details beyond observable behavior.

## Definitions
- **Width**: Target line width (in characters) used to compute dot padding so that line trailers align vertically.
- **Line header**: Indentation (subtest nesting) + test name + single trailing space.
- **Dots**: Periods inserted between line header and line trailer; minimum of 3 dots.
- **Line trailer**: Status and optional subtest counts appended after dots.

## Width Determination
1. **Default (non-terminal output)**
   - When output is not to a terminal (non-TTY), the width **must** default to the value implied by the current code: the width required by the **longest top-level test name**, the minimum dots, and the widest possible trailer.
   - This preserves existing behavior when output is piped or redirected.

2. **Default (terminal output)**
   - When output **is** to a terminal (TTY), the width **must** default to the terminal’s column width.
   - If the terminal width is unavailable or cannot be determined, fall back to the non-terminal default.

3. **Override**
   - A new command-line option `--width=N` **must** override the computed default in both TTY and non-TTY cases.
   - `N` is interpreted as a character count.

4. **Minimum width**
   - Width **must not** be less than **28**.
   - If `--width` is provided with `N < 28`, the effective width **must** be **28**.
   - If the terminal is narrower than 28 columns, the effective width **remains 28**; line wrapping is acceptable.

## Dot Calculation and Trailer Reservation
1. **Minimum dots**
   - The number of dots between header and trailer **must be at least 3**.

2. **Trailer reservation**
   - Compute dot padding by reserving space for the **longest possible trailer** for the current output mode.
   - In expanded subtest output (`-x`), reserve space for:
     - ` MMMM/NNNN not ok` (space + 4-digit counts + slash + space + `not ok`).
     - This is **17 characters** and is the **maximum** trailer length in non-UTF mode.
   - The result token `not ok` is the longest status string in non-UTF output; shorter statuses (e.g., `ok`) must still align to the same trailer column.
   - If subtest counts exceed 4 digits (i.e., N > 9999), this is **not an error**; the line may exceed the width and wrap.

3. **Header reservation**
   - Always reserve space for the full header: indent + test name + single space.

4. **Dot count formula**
   - For each line, compute:
     - `dots = max(3, width - header_len - trailer_len)`
   - If `header_len + trailer_len + 3` exceeds `width`, the line is allowed to exceed `width` and wrap.

## Name Truncation
1. **When truncation applies**
   - **Top-level test names** may be truncated only when:
     - output is to a terminal (TTY), **or**
     - `--width=N` is specified.
   - This is because top-level names are known in advance; in non-TTY default mode, width is already computed to fit them.
   - **Subtest names** may still be truncated, since their lengths are not known in advance.

2. **Truncation rules**
   - If a name would cause a line to exceed `width`, truncate the name to fit **within** the width after accounting for header, minimum dots, and trailer reservation.
   - **Never truncate a name to fewer than 8 characters.**
   - If even 8 characters plus required indentation, dots, and trailer exceed the width, the line may exceed the width and wrap.

## Minimum-Width Rationale
A width of 28 is sufficient for:
- an un-indented name of 8 characters
- 3 dots
- 4 digits for the subtest count (`MMMM/NNNN`)
- the longest result token (`not ok`)

Layout example:
```
[NAME____] ... MMMM/NNNN not ok
```

## Examples
**Current output (`prove -x`):**
```
./ZuTest ... 2/5
  foo ... ✓
  bar__ ... ✓
  baz ..... ✓
./ZuTest ... ✓
All tests successful.
Files=1, Tests=5, 5024ms wallclock (20ms usr + 0ms sys = 20ms CPU)
Result: PASS
```

**Target output (`prove -x --width=36`):**
```
./ZuTest ................ 2/5 not ok
  foo ................... ✓
  bar__ ................. ✓
  baz ................... ✓
./ZuTest ................ ✓
All tests successful.
Files=1, Tests=5, 5024ms wallclock (20ms usr + 0ms sys = 20ms CPU)
Result: PASS
```

## Acceptance Checklist
- Works with and without subtest expansion (`-x`).
- Aligns all test and subtest results vertically unless width is too small.
- Minimizes line-wrapping but does not prevent it entirely.
- Preserves existing behavior when output is non-TTY and `--width` is not specified.
