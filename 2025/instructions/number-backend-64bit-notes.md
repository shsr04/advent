# Number Backend 64-bit Notes

## Goal

Unblock real-world inputs that exceed 32-bit integer range while keeping MetaC `number` source-level semantics unchanged.

## Implemented

- Backend lowering of `number` switched from C `int` to `int64_t`.
- Updated runtime data structures and helpers:
  - `ResultNumber.value`
  - `NumberList.items`
  - `metac_parse_int` parsing via `strtoll` + `ERANGE` check
  - numeric helpers (`max`, `min`, `wrap`, size conversions)
- Updated numeric declarations/params/returns in emitted C code.
- Main-result printf path now widens `%d`/`%i` to 64-bit-safe formatting for number return printing.

## Current Limits

- Arithmetic is still fixed-width 64-bit in this backend.
- Bigint/exact integer semantics are not yet implemented.
- Silent overflow can still occur for very large arithmetic expressions.

## Next Step

Introduce checked arithmetic with promotion to bigint (or explicit overflow error mode), while keeping MetaC `number` abstract at source level.
