# Vendored bzip2 codec

These files are the library subset of upstream bzip2 1.0.8, downloaded from
<https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz>.

- Upstream SHA-256: `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269`
- Vendored files: `bzlib.h`, `bzlib_private.h`, `bzlib.c`, `blocksort.c`,
  `huffman.c`, `crctable.c`, `randtable.c`, `compress.c`, and `decompress.c`
- License: the upstream bzip2 license retained in `LICENSE`

The command-line program, examples, build scripts, and documentation are not
vendored. Cabal compiles this codec subset into the Haskell library so BZIP2
import/export works without a system development package or external process.
