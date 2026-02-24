Since we now modify the underlying matrix within the loop, we introduce a novel loop primitive:

```
if adj < 4 {
  removed++
  grid.insert("x", cell.index())
  rewind
}
```

`rewind` rewinds the program counter exactly to the start of the loop statement, causing the loop variable and iterable to be recomputed and the loop flow to start again. It acts as if we encounter the loop for the first time, except obviously any outer variables that have been modified.