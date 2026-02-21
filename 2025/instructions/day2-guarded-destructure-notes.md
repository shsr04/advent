# Day2 Guarded Destructure Notes

## Scope

This iteration adds generic compile-time arity proving for list destructuring and an inline helper for fail-fast size assertions.

## New Rules

- `const [a, b, ...] = <list-expr>` now requires compile-time proof that `<list-expr>` has exactly the same number of elements.
- A recognized proof source is a guard of the form:
  - `if <list-expr>.size() != N { return ... }`
- Proofs are flow-sensitive and apply in supported paths.

## Inline Assert Helper

- In `number | error` functions, try-expressions now support:
  - `<list-expr>.assert(x => x.size() == N, "message")?`
- Semantics:
  - runtime: fail-fast with `error("message")` when size mismatch
  - static: establishes exact-size proof `N` for the bound result

Example:

```metac
const bounds = split(range, "-")?
  .map(parseNumber)?
  .assert(x => x.size() == 2, "Invalid range expression")?

const [start, end] = bounds
```

## Intentional Restriction

- `assert(...)` first arg must be a single-parameter lambda predicate.
- Compile-time arity facts are currently extracted when predicate shape is `x.size() == N` (or `N == x.size()`) with numeric-literal `N`.
