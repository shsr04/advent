# Lang spec

The ideal solution would be something like:

```
function main() {
  printf("Result: %d\n", countNumbers() or (e) => {
    printf("Error! %s", e.message)
    return 1
  })
}

function countNumbers(): number | error {
  let dial: number with range(0,99) = 50
  
  for const line in lines(STDIN)? {
    const [direction, amount] = match(line, /(L|R)([0-9]+)/)?
  }
}
```

This code contains lots of implicit language features. For example, `error` is a record type with fields `message` and possibly `stackTrace` (tbd). There is also type inference, regex matching, error handling, and destructuring.