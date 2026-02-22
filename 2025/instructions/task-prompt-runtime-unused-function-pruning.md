# Task Prompt: Runtime Helper Usage Tracking + Pruning

Goal: stop emitting unused MetaC runtime helper functions in generated C output so builds like day3b no longer produce large `-Wunused-function` warning sets.

Scope:
- Track or infer which runtime helpers are actually referenced by emitted user/helper code.
- Keep runtime prelude generation deterministic and generic.
- Emit only the required runtime helper definitions and their transitive runtime dependencies.
- Preserve existing compiler semantics and test behavior.

Constraints:
- No day-specific logic.
- Keep code readable and modular.
- Maintain current C target/toolchain compatibility.

Validation:
- Full compiler regression suite (`make test`).
- Re-generate day3b C and verify the previously unused runtime functions are omitted.
