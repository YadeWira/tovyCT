{
  tvct.kernels.pas - bindings for the C decode kernels (src/c/tvct_kernels.c).

  The hot decode loops live in C so they can be tuned and given assembly where
  it pays; the Pascal implementations in tvct.bwt, tvct.mtf and tvct.rans stay
  as the reference used by the tests.
}
unit tvct.kernels;

{$mode objfpc}{$H+}
{$LINKLIB tvctkern}

interface

procedure kernel_bwt_inverse(const Bwt: PByte; N, Primary: Int32;
  const Samples: PInt32; NSamples, SampleRate: Int32; Outp: PByte); cdecl;
  external name 'tvct_bwt_inverse';

function kernel_mtf_rle_decode(const Tokens: PWord; Count, N: Int32;
  Outp: PByte): Int32; cdecl; external name 'tvct_mtf_rle_decode';

function kernel_rans_decode(const Src: PByte; SrcLen, K, NCtx, N: Int32;
  const CtxTab: PByte; const Freq: PInt32; Syms: PWord): Int32; cdecl;
  external name 'tvct_rans_decode';

implementation

end.
