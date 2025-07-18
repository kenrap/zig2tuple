Everything from Zig's default formatting except that all `else if` and `else` statements need to be on their own line.

For example, this is allowed ✅:
```zig
if (one) {
    // one
}
else if (two) {
    // two
}
else {
    // three
}
```

This is not allowed ❌:
```zig
if (one) {
    // one
} else if (two) {
    // two
} else {
    // three
}
```
