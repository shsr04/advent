Task Prompt: F-050 Blocker Closure and Full Normative Alignment

Objective
- Add unit tests covering all currently listed F-050 blocker items (B1..B4) as explicit reproducible cases.
- Run the compiler test suite to confirm these tests fail under current behavior.
- Enhance compiler parsing, type normalization, HIR/ABI mapping, gate checks, and C backend emission so blocker tests pass.
- Preserve strict cutover and one-shot migration constraints: no compatibility layers, no backend semantic re-checking of gate logic, and semantics outside normative reference + IR spec treated as undefined.

Authoritative Sources
- instructions/normative-reference.md
- instructions/ir-spec-f047.md
- instructions/feature-log.md (F-050 section and blocker list)

Execution Plan
1. Validate blocker definitions B1..B4 and map each to concrete parser/type/codegen locations.
2. Ensure test cases exist for each blocker item and add missing cases.
3. Run full suite to collect current failing diagnostics.
4. Implement minimal coherent compiler changes to satisfy normative behavior for each blocker.
5. Re-run full suite and ensure all tests pass.
6. Update feature log evidence and blocker status with concrete dates and outcomes.

Constraints
- Keep file length <= 500 lines and function length <= 100 lines.
- Prefer deterministic behavior and stable contracts.
- Maintain runtime allocation/free ownership correctness.
