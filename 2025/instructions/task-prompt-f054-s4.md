# Task Prompt: F-054-S4 Runtime Glue Split

Execute subtask `F-054-S4` unattended.

Objectives:
- keep backend runtime glue mechanical and separate from semantic decisions,
- make helper emission usage-driven (emit only helpers actually referenced by emitted call/method contracts),
- preserve deterministic C emission order while minimizing unused helper footprint.

Acceptance gates for this run:
1. syntax checks pass for `HIR::BackendC` and pipeline entry modules,
2. targeted runtime cases pass:
   - `compiler/tests/cases/bool_error_return_try.metac`
   - `compiler/tests/cases/c551_lexical_isblank_ok.metac`
3. UTF-8 helper path smoke compile/run passes on a dedicated local case using string `.size()` with UTF-8 bytes.
4. generated C for each target emits only used `metac_*` helper definitions.
