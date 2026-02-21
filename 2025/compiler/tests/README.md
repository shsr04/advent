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

Each test lives under `compiler/tests/cases/` with basename `<name>`.

- `<name>.metac`: required source program
- `<name>.in`: optional stdin input
- `<name>.out`: required expected stdout for compile+run tests
- `<name>.exit`: optional expected process exit code (default `0`)
- `<name>.compile_err`: if present, test is compile-fail and this file must contain an expected diagnostic substring
