# Task Prompt: F-054-S9 OpRegistry Method-Hook Propagation

Execute subtask `F-054-S9` unattended.

Objectives:
- reduce manual hardcoded method-name branching in HIR passes by routing behavior through `MetaC::HIR::OpRegistry` metadata hooks,
- propagate recently added method metadata helpers (`length_semantics`, `traceability`, `matrix_axis_argument`) into remaining callsites,
- keep behavior unchanged while improving data-driven structure.

Implementation scope:
- `compiler/lib/MetaC/HIR/Gates.pm`
- `compiler/lib/MetaC/HIR/SemanticChecks.pm`
- `compiler/lib/MetaC/HIR/SemanticChecksExpr.pm`
- `compiler/lib/MetaC/HIR/ResolveCalls.pm`
- `compiler/lib/MetaC/HIR/BackendC.pm` (targeted substitutions only)

Acceptance gate:
1. touched modules compile (`perl -I compiler/lib -c ...`),
2. full regression remains green (`make test`),
3. checklist statuses in `instructions/post-checks-f053.md` are updated to reflect progress and remaining gaps.

Risk intentionally deferred:
- complete elimination of all method-specific logic in backend optimization fast-paths,
- broader type-name de-hardcoding work across HIR modules.
