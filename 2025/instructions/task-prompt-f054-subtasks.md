# Task Prompt: F-054 Subtask Decomposition

Decompose feature `F-054` (Synthetic C Backend) into a sequence of small, from-scratch implementation subtasks such that each subtask can be completed in one unattended run. For each subtask, define:
- objective and scope boundaries,
- implementation surfaces (`compiler/lib/MetaC/HIR/*`, parser/semantic modules only when required),
- deterministic acceptance gate (explicit command and expected pass/fail condition),
- risk notes (what is intentionally deferred to later subtasks).

The decomposition must preserve the architectural rule that backend emission is purely mechanical over HIR and must not perform semantic validation or repair. The final subtask must retain `make test` green as the closure criterion.
