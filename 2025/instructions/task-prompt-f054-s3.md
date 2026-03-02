# Task Prompt: F-054-S3 Call/Method Contract Emission

Execute subtask `F-054-S3` unattended.

Objectives:
- implement mechanical `call` and `method_call` emission in `HIR::BackendC` using resolved/canonical call contracts (`call_kind`, `target_name`, `op_id`, arity),
- keep backend behavior non-semantic (no type/fallibility policy checks in backend),
- provide backend runtime glue only for directly emitted contract targets required by the S3 slice (for example builtin `log`, `parseNumber`, and `isBlank`).

Acceptance gates for this run:
1. syntax checks pass for backend/pipeline modules,
2. targeted call-heavy slice passes:
   - `compiler/tests/cases/c101_float_return_family_ok.metac`
   - `compiler/tests/cases/c551_lexical_isblank_ok.metac`
   - `compiler/tests/cases/bool_error_return_try.metac`
3. generated C for the slice contains no `Backend/F054 missing call contract` or `Backend/F054 missing method contract` markers.
