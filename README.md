# tovyCT

A fast text compressor with a good ratio: BWT followed by QLFC (libbsc's entropy
coder), with a text transform in front of the BWT that folds capitals and
replaces frequent words by short codes. Free Pascal and C, with vectorised C
kernels for the hot paths. MIT.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

**Status: 1.0, format v4 frozen.** Streams written by any 1.0 build decode with
any other, and the compressed bytes are identical on every supported platform; a
change that needs new syntax becomes v5.

## Quick start

```sh
scripts/build.sh --libsais      # build everything into build/
./build/tvct c book.txt          # -> book.txt.tvct
./build/tvct d book.txt.tvct     # -> book.txt
./build/tvct t book.txt.tvct     # verify without writing
./build/tvct i book.txt.tvct     # show the header
```

Decoding runs behind guard pages by default, so a hostile stream is a decode
error instead of a crash. `--no-guard` turns that off.

## Platforms

| OS | Architectures | State |
|---|---|---|
| Linux | x86-64 | built and tested on the host |
| Linux | AArch64 | built and tested in CI; output byte-identical to x86-64 |
| Linux | x86 (32-bit) | built and tested in CI; output byte-identical to x86-64 |
| Windows (7 and later) | x86-64 | built and tested in CI; also validated in a Windows 10 VM |
| Windows (7 and later) | x86 | built and tested in CI; also validated in a Windows 7 VM |
| macOS | AArch64 | built and tested in GitHub Actions |

macOS x86-64 is not built (discarded by decision); ARMv7 was dropped.

## Ratio

On an 85 MB text corpus, one thread:

| preset | ratio | compress | decompress |
|---|---|---|---|
| `fast` (default) | 17.35 % | 16.9 MB/s | 31.5 MB/s |
| `compact` | 17.10 % | 14.0 MB/s | 26.0 MB/s |
| `max` | 16.84 % | 9.9 MB/s | 10.4 MB/s |

With 8 threads `fast` reaches 57.2 MB/s compressing and 74.1 MB/s decompressing.
For reference, `bzip3` produces 16.90 % at 7/9 MB/s and `bsc` 17.33 % at
20/29.5 MB/s. On enwik8 (100 MB of Wikipedia) at the same block size tovyCT is
0.01-0.10 points smaller than the bsc 3.4.0 CLI: 23.76 % against 23.77 % at
8 MiB, 22.65 % against 22.75 % at 16 MiB. The full comparisons are on the
[Benchmarks](https://github.com/YadeWira/tovyCT/wiki/Benchmarks) page.

## Documentation

- **Wiki** — [Building](https://github.com/YadeWira/tovyCT/wiki/Building),
  [CLI](https://github.com/YadeWira/tovyCT/wiki/CLI),
  [C API](https://github.com/YadeWira/tovyCT/wiki/C-API),
  [Text transform](https://github.com/YadeWira/tovyCT/wiki/Text-transform),
  [Benchmarks](https://github.com/YadeWira/tovyCT/wiki/Benchmarks),
  [Decoder safety](https://github.com/YadeWira/tovyCT/wiki/Decoder-safety)
- **Format specification** — [`docs/FORMAT.md`](docs/FORMAT.md)
- **Design log and measurements** — [`docs/DESIGN.md`](docs/DESIGN.md)
- **Studies for a v5 (speed work)** — [`docs/V5-STUDY.md`](docs/V5-STUDY.md)
- **Changelog** — [`CHANGELOG.md`](CHANGELOG.md)
- **C header** — [`include/tvct.h`](include/tvct.h)

## Licence

MIT. See [`LICENSE`](LICENSE). Vendored: libsais and libbsc (Apache-2.0),
pjablake3 (MIT).

[ciBadge]: https://github.com/YadeWira/tovyCT/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/tovyCT/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/tovyCT "Latest release"
[relLink]: https://github.com/YadeWira/tovyCT/releases/latest
