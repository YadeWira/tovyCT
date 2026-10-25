{
  tvct.kernels.pas - bindings for the C decode kernels (src/c/tvct_kernels.c).

  The inverse BWT lives in C so it can be tuned and given assembly where it
  pays; the Pascal implementation in tvct.bwt stays as the reference used by
  the tests.
}
unit tvct.kernels;

{$mode objfpc}{$H+}
{$LINKLIB tvctkern}
{$IFDEF WINDOWS}{$LINKLIB msvcrt}{$ENDIF}

interface

procedure kernel_bwt_inverse(const Bwt: PByte; N, Primary: Int32;
  const Samples: PInt32; NSamples, SampleRate: Int32; Outp: PByte); cdecl;
  external name 'tvct_bwt_inverse';

implementation

end.
