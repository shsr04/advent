# Day2 Feature Review (2025)

Source reviewed: `2025/day2/day2-spec.md`

## New Features Required

1. `split(input, delim)?`
   - Must support splitting `STDIN` by delimiter.
   - Must support splitting a string value by delimiter.
   - Must support `?` error propagation.
2. Iterable sequences:
   - `for const range in ranges { ... }` where `ranges` is split result.
   - `seq(start, end)` numeric iterator for inclusive ranges.
3. Nested destructuring from `split(... ) or catch(e) { ... }`
   - Example: `const [start, end] = split(range, "-") or catch(e) { ... }`
4. Expression-level explicit error handler:
   - `expr or catch(e) { ... }` (not only `?` propagation).
5. Error constructor expression:
   - `error("...")` for explicit error return.
6. String templates/interpolation:
   - `"Invalid range expression: ${range}"`
7. Predicate for repeated-half digits:
   - `hasRepeatingDigits(x)` is part of day2 user code, not a compiler builtin.
   - Compiler requirement is generic support for bool-return user functions.

## Already Supported

- Generic functions, params, and immutable params.
- `number | error` and `number` function lowering.
- `for const line in lines(STDIN)?` loop form.
- `const [a,b,...] = match(...) ?` destructuring.
- `if/else`, `while`, `let/const`, `+=`, `++`, arithmetic/comparisons, calls.

## Gaps (Compiler)

- No array/list type/value model.
- No generic `for const x in <iterable>` (only stdin-lines loop).
- No `split` builtin with result/error model.
- No `seq` iterable builtin.
- No `or catch(e) { ... }` operator outside main special case.
- No `error(...)` expression.
- No string interpolation.
- No built-in or user-defined bool-return function calls (current call typing is number-only).

## Recommended Implementation Order

1. `F-012` Iterable model + generic `for-in` lowering (`split` arrays and `seq` ranges).
2. `F-013` Error-flow expressions: `?` generalized + `or catch(e) { ... }` expression handler.
3. `F-014` String templates/interpolation + `error(...)` constructor.
4. `F-015` Bool-return user function support in condition contexts.
