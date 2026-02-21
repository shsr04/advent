# Day2 Compiler Feature Implementation Notes

Date: 2026-02-21

Implemented in `2025/compiler/metac.pl`:

1. Iterable model for day2 patterns:
   - `const ranges = split(STDIN, ",")?`
   - generic `for const x in iterable { ... }`
   - `seq(start, end)` iterable in `for` loops (inclusive; ascending/descending).
2. Split-based destructuring with explicit handler:
   - `const [a, b] = split(source, "-") or (e) => { ... }`
3. Error-flow expressions:
   - `?` form for `split(...)?` statement pattern (propagates as `number | error` return).
   - `error("message")` expression constructor in return context.
4. String interpolation templates:
   - string literals support `${var}` for `number`, `bool`, `string`.
5. Bool-return user functions:
   - `function f(...): bool { ... }`
   - callable in condition expressions.

Validation:

- day1/day1b still compile and run.
- a day2-style compile-check program using:
  - `split(...)?`,
  - `split(...) or (e) => { ... }`,
  - `seq(start,end)`,
  - `for const ... in ...`,
  - interpolation,
  - `error(...)`,
  compiles and runs.

Design note:

- `hasRepeatingDigits(x)` remains user-defined day2 code (not a compiler builtin).
