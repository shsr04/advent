# Feature: F-006 Day1 Compiler Subset (Source -> C)

## 1) Summary

- Problem this feature solves: produce a working compiler slice that accepts the day1 drafted program style and emits correct C.
- Why now: establishes end-to-end compile pipeline early with correctness checks.
- Expected impact: unlocks iterative language growth with a tested baseline.

## 2) User-Facing Syntax (Supported Subset)

- `function main() { ... }`
- `function countNumbers(): number | error { ... }`
- `let <id>: number with range(0,99) = <int>`
- `let <id>: number = <int>`
- `for const <id> in lines(STDIN)? { ... }`
- `const [<id>, <id>] = match(<lineId>, /(L|R)([0-9]+)/)?`
- `if <id> == "L" { ... } else { ... }`
- `if <id> == 0 { ... }`
- `return <id>`

## 3) Static Semantics

- Exactly one `main` and one `countNumbers` function are required.
- `countNumbers` must return `number | error`.
- Range-constrained declaration `with range(0,99)` must initialize within `[0,99]`.
- The `match` destructuring must bind two identifiers.
- The loop source must be `lines(STDIN)?` in this subset.

## 4) Runtime/Operational Semantics

- `lines(STDIN)?` iterates line-by-line from standard input.
- `match(...)?` parses one rotation per line; parse failure returns an error.
- Dial movement is modulo 100 with wraparound.
- Count increments each time dial equals 0 immediately after a rotation.

## 5) Lowering Rules

### 5.1 Source -> Compiler IR (internal)

- Function blocks are parsed by brace depth.
- Relevant declarations/identifiers are extracted by regex-based statement parsers.

### 5.2 Compiler IR -> C

- `number | error` lowers to:
  - `typedef struct { int is_error; int value; char message[160]; } ResultNumber;`
- `lines(STDIN)?` lowers to a `fgets` loop over `stdin`.
- `match(... /(L|R)([0-9]+)/)?` lowers to strict rotation parser:
  - first char must be `L` or `R`,
  - remainder must be digits (optional trailing newline).

## 6) Correctness Contract

- Guarantees:
  - accepted day1 subset programs compile deterministically to C,
  - generated C computes the same dial transitions and zero-hit count,
  - malformed input line fails with explicit error.
- Assumptions:
  - input fits line buffer length for this initial version.
- Not guaranteed:
  - full language support beyond this subset.

## 7) Verification Plan

- Static checks:
  - required function presence/signatures,
  - range initializer bounds.
- Tests:
  - sample input from day1 task returns `3`,
  - malformed lines trigger error branch.

## 8) Status

- Stage: `implemented`
- Owner: `codex`
- Last updated: `2026-02-21`
