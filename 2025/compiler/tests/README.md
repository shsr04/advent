# Compiler Tests

Run all tests:

```bash
make test
```

Or:

```bash
perl compiler/tests/run.pl
```

## Case File Conventions

Each test lives under `compiler/tests/cases/` as a single `<name>.metac` file.

`main()` must be preceded by a `@Test({...})` annotation with JSON expectations.

Run test:

```metac
@Test({
  "stdout": "ok\n",
  "exit": 0,
  "stdin": ""
})
function main(): int { ... }
```

Compile-fail test:

```metac
@Test({
  "compile_err": "requires bool operands"
})
function main(): int { ... }
```

Optional keys:

- `stdin` (string, default `""`)
- `exit` (integer, default `0`)
- `hir` (string, exact expected HIR dump)
