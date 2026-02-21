# Day2 Seq + Chunk Adjustments Notes

## Requested Changes

1. `seq(start, end)` must accept only `number` bounds.
2. `chunk(size)` should follow lodash behavior (split into groups of size; final remainder chunk when uneven).

## Compiler Updates

- `seq` typing tightened in codegen:
  - start and end must both be `number`.
  - string-to-number coercion inside `seq` was removed.

- Added generic builtin expression:
  - `parseNumber(<string>)` as a fallible parse operation, used with `?` (or in `map(parseNumber)?`).
  - invalid input now propagates an error, not silent `0`.

- Added generic fail-fast try assignment form:
  - `const <id> = <fallible-expression>?`
  - currently supports `split(...)`, `parseNumber(...)`, and `<string_list>.map(parseNumber)`.

- Added fail-fast list mapping for day2 flow:
  - `<string_list>.map(parseNumber)?` returns a numeric list or propagates the first parse error.
  - chained form is supported, including multiline continuation:
    - `split(range, "-")?`
      `.map(parseNumber)?`

- Added inequality operator support:
  - `!=` for number/bool/string expressions.

- `chunk` runtime semantics aligned with lodash-style grouping:
  - remainder is preserved as final chunk.
  - non-positive chunk sizes now produce an empty list.

- Added list size method support:
  - `<string_list>.size()` for checking number of chunks.

## Day2 Source Update

`day2/day2.metac` now parses range bounds explicitly before `seq`:

- `start = parseNumber(startText)`
- `end = parseNumber(endText)`

`hasRepeatingDigits` now uses chunk-count validation (`.size() == 2`) rather than parity math.

## Validation

- `make -C 2025 test` passes.
- `make -C 2025 day2` passes and outputs expected sample result.
