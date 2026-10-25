{
  tvct.bsc.pas - bindings for the libbsc entropy coder (QLFC).

  libbsc is Apache-2.0, by the same author as libsais. Only its coder is used:
  bsc_coder_compress/decompress take the BWT output and apply their own RLE,
  MTF and quantized-local-frequency arithmetic coding, which measured 15 %
  smaller than this project's static MTF + rANS on text at comparable speed.

  Source: third_party/libbsc/src, with the decoder hardening fixes marked in
  the source (see README.md, "Decoder safety"; licence in
  third_party/libbsc/LICENSE). Only the bounded decode entry is bound here:
  the unbounded one trusts the stream's own block table.
}
unit tvct.bsc;

{$mode objfpc}{$H+}
{$LINKLIB bsc}
{$IFDEF DARWIN}
{$LINKLIB c++}
{$ELSE}
{$IFDEF UNIX}{$LINKLIB stdc++}{$ENDIF}
{$ENDIF}
{$IFDEF UNIX}{$LINKLIB c}{$ENDIF}

interface

const
  BSC_CODER_STATIC = 1;
  BSC_CODER_ADAPTIVE = 2;

function bsc_coder_init(features: Int32): Int32; cdecl; external name 'bsc_coder_init';
function bsc_coder_compress(input, output: PByte; n, coder, features: Int32): Int32;
  cdecl; external name 'bsc_coder_compress';

{ Decompress with the input and output sizes the caller knows: the coder
  validates its own block table instead of trusting the stream. }
function bsc_coder_decompress_bounded(input: PByte; InputSize: Int32;
  output: PByte; OutputSize: Int32; coder, features: Int32): Int32;
  cdecl; external name 'bsc_coder_decompress_bounded';

implementation

end.
