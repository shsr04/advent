# Day2 Refactor + Compiler Tests Notes

## Scope

- Refactor compiler from one large Perl file into multiple modules for readability and maintainability.
- Add tracked regression tests for compiler behavior (compile success, compile failure diagnostics, runtime outputs).

## Refactor Outcome

Compiler now has a modular layout:

- `compiler/metac.pl`: CLI entrypoint (argument parsing, file I/O)
- `compiler/lib/MetaC/Support.pm`: shared utility functions
- `compiler/lib/MetaC/Parser.pm`: parsing logic for headers, statements, expressions
- `compiler/lib/MetaC/Codegen.pm`: semantic checks, typing, C code generation, runtime prelude

## Build Integration

- `Makefile` now tracks all compiler `.pl`/`.pm` files as dependencies for `.metac -> .c` regeneration.
- Added test targets:
  - `make compiler-test`
  - `make test` (alias)

## Test Harness

- Runner: `compiler/tests/run.pl`
- Cases directory: `compiler/tests/cases/`
- Supported case artifacts:
  - `*.metac`
  - `*.in` (optional)
  - `*.out` (required for run tests)
  - `*.exit` (optional, default `0`)
  - `*.compile_err` (optional, compile-fail mode)

## Initial Coverage Added

- `lines_match_wrap`: lines iterator + regex destructuring + wrap constraints
- `number_bool_while`: number-return + bool-return function calls + while
- `split_seq_sum`: split try + split destructuring handler + seq iteration
- `string_template_condition`: interpolation template behavior in comparisons
- `split_handler_error`: explicit error-path handling via handler + `error(...)`
- `diagnostic_immutable_while`: immutable-comparison conditional diagnostic
- `diagnostic_assign_const`: immutable assignment rejection

## Verification

- `make test` passes with all added cases.
- Existing day targets still execute:
  - `make day1`
  - `make day1b`
