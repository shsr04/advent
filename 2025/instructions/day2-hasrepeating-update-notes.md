# Day2 hasRepeating Update Notes

## Task

Support the updated day2 spec style for `hasRepeatingDigits` in a generic compiler way, then verify day2 execution.

## Compiler Changes

1. Type alias support
- Added `boolean` as alias for `bool` in:
  - function parameter declarations,
  - typed variable declarations/assignments,
  - function return type normalization.

2. Expression grammar extensions
- Added multiplicative operators `*` and `/` with correct precedence over `+`/`-`.
- Added member-call postfix expression syntax:
  - `<expr>.size()`
  - `<expr>.chunk(<number>)`

3. String method lowering/runtime
- `.size()` lowers to `metac_strlen(...)`.
- `.chunk(n)` lowers to `metac_chunk_string(...)` and returns a list value (`string_list`).
- Added runtime helpers in generated C prelude:
  - `metac_strlen`
  - `metac_chunk_string`

4. Generic list destructuring
- Added generic statement form:
  - `const [a, b, ...] = <list-expression>`
- Implemented as `destructure_list` lowering for `string_list` expressions.

## Test Coverage Added

- `compiler/tests/cases/string_methods_boolean.metac`
  - verifies `boolean` alias,
  - verifies `.size()` and `.chunk(...)`,
  - verifies `/` operator,
  - verifies list destructuring from expression result.

## Validation

- `make -C 2025 test`: all compiler tests pass.
- `make -C 2025 day2`: compiles and runs successfully.
- `make -C 2025 run`: includes `day2` and prints expected sample result.

## Day2 Output Check

Running against `day2/sample-input.txt` now yields:

`Result: 1227775554`

which matches the expected sample result in `day2/day2-task.md`.
