# libsais

Suffix array construction library by Ilya Grebnov, version 2.10.4.

- Upstream: https://github.com/IlyaGrebnov/libsais
- Licence: Apache License 2.0 (see `LICENSE` in this directory). It is not
  copyleft and is compatible with this project's MIT licence; the files here
  keep their own notice.
- The three files (`libsais.c`, `libsais.h`, `LICENSE`) are unmodified.

tovyCT uses it only as an optional accelerator for suffix array construction,
selected at build time with `-dTVCT_LIBSAIS`. The pure-Pascal implementation in
`src/tvct.sais.pas` is the default and produces the same suffix arrays, so the
archive format never depends on which one was compiled in.
