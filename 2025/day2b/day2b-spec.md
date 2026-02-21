# Lang spec

With the other parts remaining the same, we need something like:

```
// Day 2 part 1 ...

function hasRepeatingDigits(input: string): boolean {
  const size = input.size()
  // divisor: number with range(1,size-1)
  for const divisor in seq(1,size-1).filter(x => size%x==0) {
    let ok = true
    // i: number with range(<divisor>,size-1) = number with range(1,size-1) 
    for const i in seq(divisor, size-1) {
      if input[i] != input[i-divisor] { // string access is proven at compile time due to range bounds
        ok = false
        break
      }
    }
    if ok { return true }
  }
  return false
}
```

This means:
- inferring number ranges at compile time
- ensuring string index access, with out-of-bounds made impossible at compile time
  - if we only know the index at runtime, then the access is fallible and needs to be error-handled