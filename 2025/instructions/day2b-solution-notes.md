# Day2b Solution Notes

## Objective

Part 2 marks an ID invalid when it is a digit sequence repeated at least twice.

## Approach Used

- Reuse the same range parsing pipeline as day2 part 1.
- For each candidate ID string `input`, test repeated-pattern validity via divisor pairs:
  - iterate `d` from `1` while `d*d <= n` where `n = input.size()`
  - when `d` divides `n` (`(n / d) * d == n`), test both chunk sizes `d` and `n/d`
- `matchesRepeatedChunk(input, chunkSize)`:
  - `chunks = input.chunk(chunkSize)`
  - require exact split (`chunks.size() * chunkSize == n`)
  - require at least 2 chunks
  - verify all chunks equal to the first

This avoids scanning all chunk sizes from `1..n/2`; it checks only divisors.

## Files

- `day2b/day2b.metac`
- `day2b/sample-input.txt`
- `day2b/real-input.txt`

## Verification

- Sample input result: `4174379265`
- Real input result: `85513235135`
- Compiler regression suite remains green: `18 passed, 0 failed`
