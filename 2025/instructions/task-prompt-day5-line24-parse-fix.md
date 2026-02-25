# Task Prompt: Resolve day5 line-24 parse error

## Objective
Reproduce and fix the parser/compiler behavior causing a parse error at line 24 in `day5/day5.metac`, while keeping grammar behavior coherent and generic.

## Required outcomes
1. Reproduce current compiler error and identify exact syntax form on line 24.
2. Determine whether the form should be allowed by current parser/typing phases.
3. Implement parser/codegen changes if this is a legitimate grammar/feature gap.
4. Add regression tests for the accepted form (and diagnostics where still invalid).
5. Re-run tests and verify no regressions.
