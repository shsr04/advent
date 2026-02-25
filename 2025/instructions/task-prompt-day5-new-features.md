# Task Prompt: Implement new day5 language features in compiler

## Objective
Extend the MetaC compiler to support the new constructs used by day5 solution code, preserving generic behavior and ownership correctness.

## Required outcomes
1. Inspect current `day5/day5.metac` and identify unsupported constructs.
2. Implement parser/codegen/runtime support for those constructs.
3. Add regression tests for each added construct and diagnostics where relevant.
4. Run full test suite and ensure no regressions.

## Constraints
- Keep feature design generic (not day-specific).
- Respect memory ownership cleanup requirements.
- Keep edits maintainable and within existing module boundaries.
