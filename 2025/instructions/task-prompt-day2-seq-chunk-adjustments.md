# Day2 Seq + Chunk Semantics Adjustment Prompt

Apply two semantic changes generically in the MetaC compiler:

1. Make `seq(start, end)` accept only number-typed bounds.
2. Make `chunk(size)` behavior match lodash semantics: split into groups of `size`, with final remainder chunk if uneven.

Then update day2 solution code to parse numeric range bounds explicitly (per spec guidance) before calling `seq`.

Deliverables:
- compiler parser/type/codegen/runtime updates,
- updated/added compiler tests,
- verified `make test` and `make day2` outputs.
