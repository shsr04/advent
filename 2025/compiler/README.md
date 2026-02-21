# MetaC Compiler (Perl, Current Subset)

This directory contains the active MetaC compiler slice in Perl.
It is feature-generic within the supported subset: the compiler does not hardcode day/domain identifiers.

## Compile MetaC -> C

```bash
perl compiler/metac.pl day1/day1.metac -o compiler/build/day1.c
```

## Build Generated C

```bash
cc -std=c11 -O2 -Wall -Wextra -pedantic compiler/build/day1.c -o compiler/build/day1
```

## Run With Sample Input

```bash
./compiler/build/day1 < day1/sample-input.txt
```

Expected output:

```text
Result: 3
```

## Supported Subset (Current)

- `function main() { ... }`
- `function <name>(): number | error { ... }`
- `function <name>(<typed params>): number { ... }`
- typed parameters:
  - `<id>: number`
  - `<id>: string`
  - numeric constraints in signatures, including `range(...) + wrap`
- wraparound behavior is explicit via `+ wrap` (not implicit from `range(...)` alone)
- function parameters are immutable (compile-time assignment rejection)
- `let <id>: number with range(0,99) + wrap = <expr>`
- `let <id>: number with <constraint + constraint + ...> = <expr>`
- `let <id>: number = <number_expr>`
- `let <id>: string = <string_expr>`
- `let <id> = <expr>` (type inference for `number`, `string`, `bool`)
- `const <id> = <expr>` with inferred immutable type (`number`, `bool`, `string`)
- `while <bool_expr> { ... }`
- compound assignment: `<id> += <number_expr>`
- increment/decrement: `<id>++`, `<id>--`
- `for const <id> in lines(STDIN)? { ... }`
- `const [a, b, ...] = match(source, /<regex-with-captures>/)?`
- producer initialization: `let <id>: <type> from () => { ... }`
- typed assignment form: `<id>: <type> [with <constraints>] = <expr>`
- expression grammar includes:
  - arithmetic: `+`, `-`
  - unary minus: `-x`
  - equality/comparisons: `==`, `<`, `>`, `<=`, `>=`
  - typed function calls: `fn(...)` for `number`-return functions
  - numeric builtins: `max(a,b)`, `min(a,b)`

## Genericity Rule

- Compiler code remains domain-agnostic.
- Day-specific behavior must come from source language features, not hardcoded compiler branches.
