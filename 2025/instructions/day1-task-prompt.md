# Day 1 Execution Prompt

Implement a first working compiler in `compiler/` for the day1 meta-language subset described in `day1/day1-spec.md`, targeting generated C.

Requirements:

1. Accept source code with the drafted constructs (`function`, typed `let`, `for const line in lines(STDIN)?`, `match(..., /(L|R)([0-9]+)/)?`, and `or`-style error handling in `main`).
2. Compile deterministically to C with explicit error paths (no silent failure).
3. Ensure generated C computes the day1 password:
   - dial starts at 50,
   - applies L/R rotations modulo 100,
   - counts how many post-rotation positions equal 0.
4. Validate correctness by compiling and running the generated C on the sample from `day1/day1-task.md`, expecting result `3`.
5. Keep supporting docs/specs under `instructions/`.
