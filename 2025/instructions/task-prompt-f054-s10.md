# Task Prompt: F-054-S10 Type Registry Bootstrap

Execute subtask `F-054-S10` unattended.

Objectives:
- start replacing hardcoded scalar type-name checks in HIR/backend paths with a centralized, data-driven type registry,
- keep runtime behavior unchanged while reducing scattered string literal logic.

Implementation scope:
- add `compiler/lib/MetaC/HIR/TypeRegistry.pm` with initial scalar categories and C-lowering metadata,
- migrate targeted callsites in `BackendC.pm` and semantic helpers where scalar-type checks are currently duplicated.

Acceptance gate:
1. touched modules compile (`perl -I compiler/lib -c ...`),
2. full regression remains green (`make test`),
3. checklist reflects partial progress for the type-name de-hardcoding item.

Risk intentionally deferred:
- full replacement of all type-name checks across every HIR module,
- generalized container/matrix type policy registry beyond scalar bootstrap data.
