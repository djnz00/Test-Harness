establish an output `width` to right-align output from `prove`
- currently `prove` uses the longest test name to compute the number of dots to right-align results with
  - the current width is implied by the longest test name, the minimum number of dots (3), and the widest possible test result that follows the dots
- if the output is not to a terminal, the width should default to that required by the longest test name (per the current code)
- if the output is to a terminal, the width should default to the console terminal width
- the width can be overridden with a command-line argument `--width=N`
- the width cannot be less than 28 (output line wrapping is fine if the terminal window is narrower than that)

example of what IS with `prove -x`:

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

example of what WILL BE with `prove -x --width=36`:

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

to calculate the number of periods/dots:
- the minimum number of dots is 3
- reserve enough space at the end of the line for the line trailer:
  - ` MMMM/NNNN not ok`, i.e. for up to 9999 subtests and a failure result in non-utf mode
    - if the N exceeds 9999, this is not an error and the line can exceed the width and wrap
  - this is 17 characters, but verify that `not ok` is the longest result that could be appended and calculate accordingly
- reserve enough space at the beginning of the line for the line header which is the subtest indent and the name, followed by a single space ` `

the minimum width of 28 is enough for:
- an un-indented name of 8 characters
- 3 `.` dots
- 4 digits for the number of subtests, i.e. 9 characters `MMMM/NNNN`
- and `not ok` for the result:
```
[NAME  ] ... MMMM/NNNN RESULT
```

name truncation:
- name truncation only occurs for top-level test names when outputting to a terminal or --width=N is specified
  - this is because top-level test names are known in advance, the width is otherwise computed from the longest top-level test name, and the width would therefore accommodate all of them
  - subtest names might still get truncated, because they are not known in advance
- if the length of a name would cause the line to exceed the width, the name should be truncated to fit the line within the width
- names should never be truncated to fewer than 8 characters
- line length can still exceed the width and wrap if the truncated name combined with the indent, dots and trailer requires that

checklist:
- the new right-alignment code should:
  - work both with and without subtest expansion (`-x`)
  - align all test and subtest results vertically unless the width is too small
  - minimize the likelihood of line-wrapping but not prevent it entirely
