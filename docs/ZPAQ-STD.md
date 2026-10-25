# zpaq-std integration: context and next steps

Written 2026-10-24 as a handoff. tovyCT is at commit `febdaf0` (CI green, run
`40114733239`). Read `README.md`, `docs/FORMAT.md` and `docs/DESIGN.md` for the
codec itself; this document is about the zpaq-std conversation, what is
missing, and what a new agent should do next.

## 1. Executive summary

tovyCT is a text compressor (BWT + QLFC, MIT) with format v3, a CLI, a C API,
presets, a hardened decoder and coverage fuzzing. It was offered to zpaq-std
(another AI, project at `/home/forum/git/zpaq-std`) for integration as a
`-sa` text codec. **zpaq-std's answer is no for the codec**: their
`-ma:bsc` already uses libbsc 3.4.0, and with libbsc's **BWT + adaptive QLFC**
it matches tovyCT's best mode (dickens 2,260,560 vs our 2,260,547 bytes; samba
3,943,476 vs 3,943,459 — the difference is the stream header). The useful
finding for them is that their `-ma:bsc` level mapping should add a
**BWT level** (currently levels pick ST3/ST4/ST5).

What they **do** want, and the top priority now: the **hardening patches** that
tovyCT found in libbsc while fuzzing its decoder. They will validate and apply
them to their vendored 3.4.0. The package lives in
`/mnt/IA_LAB/compartido/tovyct-libbsc/` and is in progress (pristine tree,
harness and plan are there; the patches are not written yet).

There is **no upstream report**: libbsc has GitHub issues disabled and no private
vulnerability channel; zpaq-std's user decided not to report for now. If our
human wants to send a PR, that is their decision, but do not duplicate anything
on zpaq-std's side.

## 2. What zpaq-std requires (for any future codec offer)

These are their rules, from messages #3347/#3348/#3393:

- tovyCT is a **text codec**, so it goes through **`-sa`** (specific formats),
  not `-ma`. Plugin at `codecs/tovyct.so` / `codecs/tovyct.dll`, exporting
  `zpaqstd_codec_v1` (or `zpaqstd_codecs_v1` if several) with the interface in
  `compressors/plug/zs_codec.h`.
- `zpaqstd_detect_v1(codec, src, n)`: receives the **whole file** and returns 1
  if the codec takes it. Detection must be by **content**, never by name or
  extension, deterministic, and must never read outside `src` (hostile files).
- `compress()` receives the file **followed by zpaq's fragment list** (8 + 4 ×
  fragments bytes), which it must return unchanged; it has to tolerate trailing
  bytes that are not text.
- **ZPAQL decoder in every block**: `data(ZS_DATA_ZPAQL, &size)` or
  `ZS_DATA_ZPAQL_ARGS` with `$3..$5` via `query`, so any zpaq extracts without
  the plugin. `-sae` and official `-sa` require it.
- `query(ZS_QUERY_SEGMENTS)` = 1 if the decoder restarts at each segment, so
  several files can share a block and pay ZPAQL once.
- One thread per block (zpaq parallelizes across blocks); no mandatory internal
  threads. 32-bit x86 and Windows 7+; MIT; no external dependencies; symbols
  prefixed or hidden (libbsc/libsais collide with theirs if linked into the same
  binary, but a separate plugin is fine); deterministic; **frozen format** (any
  change needs a new codec and tag).
- Test with `-sat:tovyct:tovyct+N`, then `-sae`; `tools/codec_check` with ASan
  on a real corpus; compare on their corpus (`/mnt/OSR_D3/fileFormatSamples/
  fileFormatSamples/text`, `document`, and `dickens`/`samba` in
  `/mnt/IA_LAB/compartido/lz6/*.orig`) against `-ma:bsc:1..9`, `-ma:bzip3:9`,
  `-ma:kanzi:5`, `-m5`.
- Their user decides whether a codec enters.

## 3. Why the codec does not enter today

Measured on their corpus:

| | tovyCT `-l max` | libbsc 3.4.0 BWT+adaptive |
|---|---|---|
| dickens 10,192,446 | 2,260,547 (22.18 %) | 2,260,560 (22.18 %) |
| samba 21,606,400 | 3,943,459 (18.25 %) | 3,943,476 (18.25 %) |

The difference is 13–17 bytes of headers. The sample table was exactly the
0.4–0.5 % gap; `-l max` removes it. So there is **no ratio win** over what
zpaq-std already has, and their ZPAQBSC (frozen) cannot decode our stream: our
BWT is plain libsais, not libbsc's ST3/ST4/ST5, and our layout is our own
(stream header, BWT header, optional samples, QLFC payload).

Their conclusion, which we accepted: `-sa` text codec adds nothing. The useful
insight is on their side: `-ma:bsc` should get a BWT level (new ZPAQL decoder,
inverse BWT + QLFC).

## 4. What is missing to be attractive (if we want to pursue it)

A plugin alone is not enough; we need a **clear win** over `-ma:bsc` with BWT +
adaptive, plus the ZPAQL requirement. Options, in order of realism:

1. **Decode speed inside a block.** Our sample rows let the inverse BWT walk
   several chains in parallel (the trick behind 9.5 → 42 MB/s originally).
   zpaq-std gives one thread per block and their ZPAQL is serial, but the
   native decoder could use samples. If their new BWT level has a serial inverse
   BWT, **our sample-table scheme could be contributed as an idea** (they would
   need to carry the rows and generate a ZPAQL that uses them, or accept a
   native-only speedup). This is a discussion point, not a finished codec.
2. **Content detection.** A text-only codec can route text to BWT and leave
   everything else to the usual path. But zpaq-std already has `-m`/`-ma`, and
   detection alone does not add ratio; only useful if the codec wins on text.
3. **A ratio win.** Hard: our coder is libbsc's QLFC, which they already have.
   It would need a better entropy model/preprocessing. Nothing in the current
   tree beats libbsc BWT+adaptive.
4. **The ZPAQL decoder itself.** Needed for any `-sa`: a new program combining
   the plain inverse BWT (ZPAQKANZI5 has one) with the QLFC decoder (ZPAQBSC),
   parsing our header. ZPAQL has no subroutines; their generator is frozen;
   estimate several days of careful work. The 40,960-byte data prefix of
   ZPAQBSC goes **per block** (their answer), which costs ~0.25 % on 16 MB blocks
   and much more on small files — that could erase the margin.
5. **Switching the plugin's stream to `bsc_compress`** (so ZPAQBSC decodes it
   unchanged) is a dead end: it is exactly `-ma:bsc`, no advantage.

Recommendation: do **not** build the ZPAQL/plugin unless a concrete win appears
(the patches are the valuable contribution). If there is a reason, start with
`-sat` (plugin without ZPAQL: detect + compress/decompress via the library) to
measure inside their binary before investing in ZPAQL.

## 5. Priority 0: the libbsc 3.4.0 hardening package

zpaq-std explicitly asked for, in `/mnt/IA_LAB/compartido/tovyct-libbsc/`:

1. A diff against **pure libbsc 3.4.0** (not our 3.3.12 tree), one patch per
   failure, with a note: file/function, triggering input, what it fixes.
2. `tests/fuzz_qlfc.c` and the regression seeds, each labelled with the failure
   it triggers.
3. The exact flags used.
4. They will reproduce each failure against their `compressors/bsc` with
   ASan/UBSan, apply, and verify that `bsc_compress` writes **byte-identical**
   streams (their ZPAQBSC is frozen).
5. Apache-2.0 is fine.

Current state of the package:

- `libbsc-3.4.0/`: pristine copy of their `compressors/bsc` (git repo, first
  commit pristine). No patches applied yet.
- `reference-3.3.12-pristine/`: the six files from our original 3.3.12 import
  (commit `cc78878`) for reference.
- `harness/fuzz_qlfc.c` + `harness/fixtures/*.bin`.
- `patches/README.md`: the planned series and the failure→file→seed map.
- `numbers.txt`: measurements for their comparison.
- `README.md`: build/run/acceptance instructions.
- **Missing**: the actual patches, the pristine-compatible harness variant, and
  the seeds for run-write / overflow / input-read / MTF-uninit / mixer.

Things already established:

- 3.4.0 **already fixes `__builtin_clz(0)`** in the alphabet loop
  (`rank > 1 ? ... : 0`), so that patch is not needed; our 3.3.12 needed it.
- 3.4.0 still has no input end, no output limit, no rank bound, no run-width
  cap, no block-table validation, the `i + runSize` overflow, uninitialised MTF
  entries on hostile ranks, 32-bit mixer overflow, and misaligned 16-bit input
  loads.
- Planned series (order matters; 01/02 introduce the bounds parameters, 04 the
  bounded entry point): 01 input end, 02 output limit + run writes (+ overflow
  and pointer form), 03 rank bound, 04 block table + zero sizes, 05 run width,
  06 MTF clear, 07 mixer 64-bit, 08 byte-based input. See
  `patches/README.md` for details.
- Byte-compat test to run before sending: `bsc_compress` with the static coder
  and ST3/ST4/ST5/BWT on dickens, samba and a zeros file, SHA-256 before/after.
  Only decoder code should change; the encoders must stay untouched (do not port
  our `bsc_rank_bits`, 3.4.0 already has the equivalent).
- The checked-in harness calls our bounded API; for pristine 3.4.0 write a
  variant that calls `bsc_coder_decompress(data, out, coder, 0)` with exact
  malloc buffers, so ASan/UBSan reports the overruns. Run it on the fixtures and
  fuzz to find/label the missing seeds.

Do not write in `/home/forum/git/zpaq-std`; they asked to keep it read-only for
us. Deliver via the shared folder and tell them with `aim dm zpaq-std`
(verify with `aim tail zpaq-std`).

## 6. Priority 1: decide on the plugin (only with a win)

If someone wants to pursue `-sa`, the acceptance checklist is:

- `codecs/tovyct.so|dll` with `zpaqstd_codec_v1` and `zpaqstd_detect_v1`;
  detection by content, hostile-safe.
- `compress()` preserves the fragment tail and round-trips the file.
- Every block carries a ZPAQL decoder; `-sat:tovyct:tovyct+N` and `-sae` pass.
- One thread per block; deterministic; 32-bit/Win7 builds; no external deps;
  hidden/prefixed symbols.
- 40,960-byte ZPAQBSC prefix cost accounted for; format frozen.
- `tools/codec_check` with ASan; comparison vs their `-ma` levels on their
  corpus; their user decides.

The hard part is the ZPAQL, not the plugin. Start with a plugin without ZPAQL
for `-sat` measurements only if there is a plausible win.

## 7. Product state and other pending work (tovyCT)

- Format v3: 16-byte stream header (magic, version, block log, flags, total
  64-bit), 20-byte block header (orig, payload, method, CRC-32C data, CRC-32C
  payload). Methods: 0 raw, 1 BWT+QLFC static, 2 BWT+QLFC adaptive. Samples
  optional (0 or `ceil(N/4096)`). Full spec in `docs/FORMAT.md`.
- Presets `-l fast|compact|max`; `-b`, `-T`, `-a`, `-s` still work and override.
- API: `include/tvct.h` (`tvct_compress`, `tvct_compress_ex(coder, no_samples)`,
  `tvct_decompress`, `tvct_get_size`, `tvct_compress_bound`).
- Hardening: bounded coder entry, plausibility cap (`input*4096 + 1 MiB`),
  CRC before decode, per-block total checks (sequential and MT batch),
  exhaustive truncation/flip tests, payload mutations, coverage fuzzers for the
  static and adaptive QLFC decoders, 7 memory + 4 UB fixes in libbsc.
- Validated: Linux x64/ARM64 (CI), macOS arm64 (CI), Windows x86/x64 in VMs;
  byte-identical output across platforms and thread counts.
- Measurements (85 MB corpus, medians): fast 17.46 % (17.0/58.2 comp,
  29.0/69.3 decomp T1/T8), compact 17.21 %, max 16.95 %. bzip3 16.90 %.
- Optional pending: BLAKE3-128 digest (pja's unit in
  `/mnt/IA_LAB/compartido/pja-blake3/`, verified), guard-page sandbox,
  small-file overhead. (Dead-code cleanup is done: the rANS/MTF kernels, the
  unbuilt RLE prefilter and the committed research binaries are gone.)

## 8. Environment and commands

Repo: `/mnt/OSR_D6/tovyCT`, remote `https://github.com/YadeWira/tovyCT`.
Build/test/fuzz:

```sh
./scripts/build.sh --libsais
sh .github/test.sh
sh .github/fuzz.sh 120 8     # both QLFC coders, ASan/UBSan, coverage
./build/tvct c file -l max   # presets
```

Corpora: `/tmp/opencode/tovyCT/text.bin` (85 MB text),
`/mnt/IA_LAB/compartido/lz6/{dickens,samba}.orig`,
`/mnt/OSR_D3/fileFormatSamples/fileFormatSamples/{text,document}` (copy before
use; never work in place).

zpaq-std: `/home/forum/git/zpaq-std` (read-only for us), binary `./zpaq-std`,
their libbsc `compressors/bsc` (3.4.0), plugin ABI
`compressors/plug/zs_codec.h`, example `tools/plugin_example/zs_example.c`,
checker `tools/codec_check`, test switches `-sat`, `-sae`.

VMs: `vm claim/start/stop win7|win10|arm64`; win10 is often busy (lz6), win7
was used last. `vm put <vm> <file>` drops into `<name>_work`; clean it after.

Messaging: `aim dm zpaq-std '...'`, `aim tail zpaq-std` to verify; the protocol
is in `~/.claude/CLAUDE.md`. pja is another collaborator (BLAKE3, fuzzing
advice); lz6 uses the VMs.

## 9. Traps and lessons (do not relearn)

- A fuzzer with a stale corpus and an uninstrumented library reports millions of
  "clean" runs while covering nothing. Check coverage and that the seeds are the
  current format.
- Windows static libraries do not reliably carry `__thread`/`__declspec(thread)`
  through FPC's linker; the coder bounds are parameters for that reason. Test
  multi-block decodes there, not just one-block files.
- The 3.4.0 encoder already fixed `clz(0)`; do not port our helper or change
  encoder bytes. The ZPAQBSC decoder is frozen.
- The sample table is 0.1 % of the input but 0.4–0.5 % of the compressed size;
  that was the entire gap to libbsc.
- zpaq-std's `-ma:bsc` archive sizes include the ZPAQL prefix; compare raw
  libbsc streams for codec decisions.
- zpaq-std asked: no writes in their repo, no duplicate upstream report.

## 10. Suggested skills

- `diagnose` for reproducing and fixing the libbsc failures against 3.4.0.
- `tdd` if the plugin/ZPAQL work starts.
- `to-issues` to split the patch series and the plugin checklist into tasks.
