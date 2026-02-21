# Makefile Build-Chain Prompt

Create a generic `Makefile` that builds artifacts from:

1. `.metac` source files,
2. generated `.c` files,
3. compiled binaries.

Requirements:

- Auto-discover day sources (e.g., `day1/day1.metac`, `day2/day2.metac`, ...).
- Keep dependency chaining explicit so incremental rebuilds are correct.
- Provide clear top-level targets for generating C, building binaries, and running sample inputs when available.
- Avoid any hardcoded puzzle/domain logic in build rules.
