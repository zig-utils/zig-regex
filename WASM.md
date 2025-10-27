# WebAssembly (WASM) Support

The zig-regex library can be compiled to WebAssembly for use in web browsers and Node.js.

## Building for WASM

### Basic WASM Build

```bash
zig build-lib src/root.zig -target wasm32-freestanding -dynamic -rdynamic
```

### Optimized WASM Build

```bash
zig build-lib src/root.zig \
    -target wasm32-freestanding \
    -dynamic \
    -rdynamic \
    -O ReleaseSmall \
    --name regex
```

This will produce `regex.wasm` which can be loaded in browsers or Node.js.

## JavaScript/TypeScript Integration

### Browser Usage

```javascript
// Load the WASM module
const wasmModule = await WebAssembly.instantiateStreaming(
    fetch('regex.wasm'),
    {
        env: {
            // Provide any required imports
        }
    }
);

// Use the exported functions
const exports = wasmModule.instance.exports;

// Example: compile a regex
const pattern = "\\d+";
const regex = exports.zig_regex_compile(pattern);

// Check for match
const input = "test 123";
const matches = exports.zig_regex_is_match(regex, input);
console.log('Matches:', matches === 1);

// Clean up
exports.zig_regex_free(regex);
```

### Node.js Usage

```javascript
const fs = require('fs');
const path = require('path');

// Load WASM file
const wasmPath = path.join(__dirname, 'regex.wasm');
const wasmBuffer = fs.readFileSync(wasmPath);

// Instantiate
WebAssembly.instantiate(wasmBuffer, {
    env: {
        // Provide imports if needed
    }
}).then(result => {
    const { zig_regex_compile, zig_regex_is_match, zig_regex_free } = result.instance.exports;

    // Use the library
    const regex = zig_regex_compile("hello.*world");
    const matches = zig_regex_is_match(regex, "hello beautiful world");

    console.log('Pattern matches:', matches === 1);

    zig_regex_free(regex);
});
```

## TypeScript Bindings

Create a TypeScript wrapper for type safety:

```typescript
// regex.d.ts
export interface WasmRegex {
    compile(pattern: string): number | null;
    isMatch(regex: number, input: string): boolean;
    find(regex: number, input: string): Match | null;
    free(regex: number): void;
}

export interface Match {
    text: string;
    start: number;
    end: number;
}

// regex.ts
export class Regex {
    private wasm: WasmRegex;
    private handle: number;

    constructor(wasm: WasmRegex, pattern: string) {
        this.wasm = wasm;
        const handle = wasm.compile(pattern);
        if (handle === null) {
            throw new Error('Failed to compile regex pattern');
        }
        this.handle = handle;
    }

    isMatch(input: string): boolean {
        return this.wasm.isMatch(this.handle, input);
    }

    find(input: string): Match | null {
        return this.wasm.find(this.handle, input);
    }

    free(): void {
        this.wasm.free(this.handle);
    }
}
```

## Memory Management

The WASM build uses the C allocator, which means:

1. **Manual memory management**: You must call `free` functions to avoid memory leaks
2. **Linear memory**: WASM has a linear memory model that grows as needed
3. **Memory limits**: Browser WASM instances have memory limits (typically 2GB-4GB)

### Best Practices

```javascript
class RegexManager {
    constructor(wasmExports) {
        this.exports = wasmExports;
        this.regexes = new Map();
    }

    compile(pattern) {
        const handle = this.exports.zig_regex_compile(pattern);
        if (handle) {
            this.regexes.set(handle, pattern);
        }
        return handle;
    }

    isMatch(handle, input) {
        return this.exports.zig_regex_is_match(handle, input) === 1;
    }

    free(handle) {
        if (this.regexes.has(handle)) {
            this.exports.zig_regex_free(handle);
            this.regexes.delete(handle);
        }
    }

    freeAll() {
        for (const handle of this.regexes.keys()) {
            this.exports.zig_regex_free(handle);
        }
        this.regexes.clear();
    }
}
```

## Performance Considerations

### WASM Performance Tips

1. **Compile patterns once**: Regex compilation is expensive, cache compiled patterns
2. **Minimize string copies**: Pass string pointers when possible
3. **Batch operations**: Process multiple inputs with the same pattern
4. **Use SharedArrayBuffer**: For multi-threaded WASM (with proper atomics)

### Benchmarks

Typical performance for WASM vs native:

- **Compilation**: ~1.5-2x slower than native
- **Matching**: ~1.2-1.5x slower than native
- **Memory**: Similar to native (slightly higher overhead)

## Build Options

### Minimal Build

For smallest file size:

```bash
zig build-lib src/root.zig \
    -target wasm32-freestanding \
    -O ReleaseSmall \
    -dynamic \
    -rdynamic \
    --strip
```

### Debug Build

For development with debugging symbols:

```bash
zig build-lib src/root.zig \
    -target wasm32-freestanding \
    -O Debug \
    -dynamic \
    -rdynamic
```

## Limitations

Current WASM build limitations:

1. **No threading**: Single-threaded execution (use Web Workers for parallelism)
2. **C allocator only**: Uses malloc/free from WASM runtime
3. **Limited OS APIs**: No direct file system access
4. **String handling**: Requires careful UTF-8 handling at the boundary

## Future Improvements

Planned enhancements for WASM support:

- [ ] Automatic string marshalling helpers
- [ ] TypeScript definition generation
- [ ] NPM package for easy integration
- [ ] WASM-optimized build target
- [ ] Streaming API for large inputs
- [ ] Worker pool for parallel matching

## Example Projects

See `examples/wasm/` directory for:

- Basic browser integration
- Node.js usage
- React/Vue component wrappers
- Performance benchmarks
- TypeScript bindings

## Resources

- [WebAssembly MDN](https://developer.mozilla.org/en-US/docs/WebAssembly)
- [Zig WASM Target](https://ziglang.org/documentation/master/#WebAssembly)
- [WASI](https://wasi.dev/) - WebAssembly System Interface
