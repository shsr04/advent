# Lang spec

Given the new requirements in this day, the language should evolve as follows:

```
// main(), ...

function findRanges(): number | error {
  const ranges = split(STDIN, ",")?
  let invalidSum = 0
  
  for const range in ranges {
    const [start, end]: number[] with size(2) = split(range, "-") or catch(e) {
      return error("Invalid range expression: ${range}")
    }
      .map(parseNumber)? // builtin: parses string to number
      .assert(x => x.size() == 2, "Invalid range expression: ${range}")?
    
    for const x in seq(start, end) {
      if hasRepeatingDigits("${x}") {
        invalidSum += x
      }
    }
  }
  
  return invalidSum
}

// Look for numbers which consist of a sequence of digits repeated exactly once, like 123123.
function hasRepeatingDigits(input: string): boolean {
  const chunks = input.chunk(input.size()/2)
  if chunks.size() != 2 {
    return false
  }
  
  const [head,tail] = chunks
  return head == tail
}
```

You can see:
- string templates for convenient formatting
- `seq` for numeric sequences
- two ways of error handling: either by `?` or by explicit handler
