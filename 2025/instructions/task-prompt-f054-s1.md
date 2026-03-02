# Task Prompt: F-054-S1 Backend Skeleton

Implement subtask `F-054-S1` from scratch:
- ensure `compiler/lib/MetaC/HIR/BackendC.pm` exists and provides deterministic function/region skeleton emission,
- ensure scheduling uses `region_schedule` when available and remains deterministic if it is missing/partial,
- keep backend mechanical only (no semantic validation/recovery decisions in backend code paths),
- ensure the compile pipeline can emit C by default through the new backend.

Acceptance gates:
1. `perl -I compiler/lib -c compiler/lib/MetaC/HIR/BackendC.pm`
2. `perl compiler/metac.pl <smoke.metac> -o <out.c>`
3. Output in `<out.c>` is C source text (not HIR dump).
