# Task Prompt: F-054-S8 Full Conformance Closure

Execute subtask `F-054-S8` unattended.

Objective:
- close remaining backend/runtime gaps revealed by the full regression corpus while preserving the synthetic backend architecture (no backend semantic-policy enforcement),
- drive the acceptance gate to green:
  - `make test` must report all tests passing.

Execution policy:
- iterate on failure clusters in priority order from latest `make test` output,
- after each significant fix batch, rerun targeted cases first, then rerun full `make test`,
- keep changes localized to backend/runtime emission and clearly mechanical wiring unless an upstream blocker must be fixed for conformance.
