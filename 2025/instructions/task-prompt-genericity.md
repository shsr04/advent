# Genericity Enforcement Prompt

Refactor compiler implementation so it does not hardcode domain logic or day-specific identifiers.

Requirements:

1. Compiler must not require specific user function names (e.g. `countNumbers`).
2. Compiler must not reference domain variables (e.g. `dial`) anywhere in compiler logic.
3. Language features implemented for one day must be reusable for any valid code using those features.
4. Keep day1 validation behavior by compiling the provided day1 source without puzzle-specific compiler branches.
