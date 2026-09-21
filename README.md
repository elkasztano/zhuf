# zhuf

`zhuf` is a high-performance key-value command-line shuffling utility written in Zig 0.16.0. It processes streams or files, tokenizes them by custom delimiters, and rearranges items using either pseudo-random generators or multi-round deterministic card-shuffling algorithms.

---

## Features

* **Key-Value Options Interface**: Direct `key=value` CLI syntax with support for `dd`-style size suffixes (`k`, `M`, `G`, `b`).
* **Flexible I/O Handling**: Stream directly from `stdin` / `stdout` or specify input/output files (`if=...`, `of=...`).
* **Custom Token Delimiters**: Split inputs on any custom single character, default newlines (`\n`), or null bytes (`delimiter=null`).
* **Pseudo-Random Shuffling**: Fast PRNG algorithms (`xoroshiro128`, `xoshiro256`, or default PRNG) with customizable or secure fallback seeding.
* **Deterministic Shuffling**: Multi-pass algorithms (`milk`, `monge`, `faro`) with optional iteration counts (e.g., `algo=milk:5`).
* **Output Limit & Formatting Control**: Limit output count (`count=N`, supports size suffixes) and omit trailing newlines (`-n`).
* **Shuffle Positional Arguments**: Shuffle positional arguments instead of stream input. (`-e`).

The `dd`-style size suffixes are a quirky leftover from a previous project.

---

## Memory Architecture & Performance

`zhuf` is optimized for high-throughput stream and file shuffling on large datasets. Rather than allocating individual strings or storing 16-byte slice descriptors (`[]const u8`), `zhuf` reads the entire dataset into a single contiguous buffer and indexes token positions using compact byte offsets relative to the buffer's base address.

### Offset Indexing (`TokenList`)

* **32-Bit Compact Offsets (`u32`):** For input files under 4 GiB, token locations are stored as 32-bit unsigned integers. This reduces memory consumption to **4 bytes per token** (a 50% reduction compared to raw 64-bit pointers and 75% reduction compared to slices).
* **64-Bit Scaling (`u64`):** When inputs equal or exceed 4 GiB, `zhuf` dynamically selects 64-bit offsets via a zero-cost tagged union (`TokenList`).
* **In-Place Tokenization:** Delimiters in the primary input buffer are modified in-place to null terminators during single-pass tokenization, eliminating dynamic string allocations.
* **Vectorized Output Formatting:** Output assembly resolves offset boundaries into contiguous string spans, leveraging compiler SIMD vectorization (`@memcpy`) to fill output buffers before flushing to standard output or disk.

---

## Requirements

* **Zig Compiler**: Version `0.16.0`.

---

## Building from Source

Build `zhuf` using the Zig toolchain:

```bash
zig build -Doptimize=ReleaseFast
```

This will create the binary in `zig-out/bin`.

---

## Installation

The current recommendation is to simply create a symlink in a directory in your `PATH`.
Example for systems based on Debian:

```bash
# make sure you are in the project's main directory
ln -s "$PWD/zig-out/bin/zhuf" ~/bin/zhuf
```

To uninstall delete the above created symlink:

```bash
rm -v ~/bin/zhuf
```

---

## Usage Syntax

```
zhuf [options]
zhuf -e [options] [arg...]
```

### Options (`key=value`)

| Option | Type / Format | Default | Description |
| :--- | :--- | :--- | :--- |
| `if` | `<path>` | `stdin` | Input file path. |
| `of` | `<path>` | `stdout` | Output file path. |
| `seed` | `<u64>` | *urandom* | PRNG seed value. |
| `count` | `<usize>` | *All* | Maximum number of shuffled items to output. Supports size suffixes. |
| `delimiter` | `<char\|null>` | `\n` | Token delimiter. Pass either single character or `null` for `\0`. |
| `algo` | `<algorithm>` | *Default PRNG* | Select shuffle algorithm (see below). |

### Flags

| Flag | Description |
| :--- | :--- |
| `-e`, `-echo`, `--echo` | Shuffle positional arguments instead of stream input. |
| `-n`, `-nonewline`, `--no-newline` | Omit trailing newline at the end of output. |
| `-h`, `-help`, `--help` | Display usage options and exit. |

---

## Shuffle Algorithms

### 1. Pseudo-Random Algorithms
Random shuffles run in a single pass using standard Fisher-Yates array shuffling.

* **`xoroshiro128`**: Shuffles using the 64-bit `Xoroshiro128` generator.
* **`xoshiro256`**: Shuffles using the 64-bit `Xoshiro256` generator.
* *(omitted)*: Default fallback uses Zig's standard default PRNG.

The PRNGs are initialized with system OS entropy unless a seed is specified.
If system OS entropy is not available, a clock timestamp is used instead.

### 2. Deterministic Multi-Round Algorithms
Deterministic algorithms rearrange items according to precise mathematical permutation patterns. You can specify an optional iteration count using `:N` (e.g., `algo=monge:3`). Custom PRNG seeds are ignored by these algorithms.

* **`milk`**: Interleaves elements working from the outer edges inwards towards the middle.
* **`monge`**: Monge's shuffle; alternates placing elements between the front and back of the array.
* **`faro`**: Perfect out-shuffle interleaving the top and bottom halves of the sequence.

---

## Examples

### Basic Pipe Shuffling
Shuffle lines from standard input:
```bash
seq 1 10 | zhuf
```

### Custom Delimiters and Output Limit
Shuffle comma-separated values and output only 3 items:
```bash
echo -ne "apple,banana,cherry,date,fig" | zhuf delimiter="," count=3
```

### Deterministic Multi-Pass Shuffle
Apply 4 rounds of the Milk shuffle algorithm to a file:
```bash
zhuf if=deck.txt of=shuffled.txt algo=milk:4
```

### Seeded Pseudo-Random Shuffle
Use `xoshiro256` with a fixed seed for reproducible shuffles:
```bash
zhuf if=test.txt seed=98765 algo=xoshiro256
```

### Null-Terminated Input (`xargs` integration)
Shuffle null-delimited tokens:
```bash
find . -type f -print0 | zhuf delimiter=null | tr '\0' '\n'
```

### Shuffle positional arguments
Shuffle positional arguments using the `--echo` flag:
```bash
zhuf --echo alpha beta gamma delta
```
