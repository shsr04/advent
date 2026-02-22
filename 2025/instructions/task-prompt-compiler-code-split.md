# Compiler Code-Split Prompt

Refactor the MetaC compiler implementation into smaller, readable components without changing behavior.

Scope:
1. Split `compiler/lib/MetaC/Codegen.pm` helpers into focused modules while preserving public behavior.
2. Keep `compile_source` API stable (`MetaC::Codegen::compile_source`).
3. Keep generated C output behavior equivalent for existing language features.
4. Preserve and run existing regression tests.
5. Update docs/feature log with the refactor evidence.

Constraints:
- No day-specific logic.
- Keep module boundaries practical and maintainable.
- Minimize risk by moving cohesive helper groups first (types, scope/facts, runtime prelude).
