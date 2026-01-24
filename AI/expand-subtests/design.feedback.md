Requirements feedback
- combining parallel execution and subtest expansion is a requirement
- -x N or --expand=N can be used to specify the maximum indent level, permitting nested subtest expansion

The Non-goals are questionable:
- not changing TAP::Parser behavior and not treating subtests as real test programs in the aggregator may prevent subtest expansion during parallel execution with `jobs > 1`
  - treating subtests consistently with top-level test programs may facilitate extending parallel execution to subtests
