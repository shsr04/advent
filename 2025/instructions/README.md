# Meta Language Working Docs

This directory is the canonical workspace for designing a meta language that compiles to C with machine-checkable correctness constraints.

## Workflow

1. Add or refine one feature at a time in `feature-log.md`.
2. Write a full feature spec using `feature-template.md`.
3. Update `correctness-framework.md` with any new proof obligations.
4. Mark the feature status only when it passes the verification gates.

## File Map

- `language-charter.md`: project goals, invariants, and non-goals.
- `feature-log.md`: roadmap and per-feature status.
- `feature-template.md`: required structure for each feature proposal.
- `correctness-framework.md`: proof model and release gates.

## Current Priority

Build an expressive, practical language with:

- clear static semantics,
- deterministic compilation to C,
- explicit safety and correctness guarantees.
