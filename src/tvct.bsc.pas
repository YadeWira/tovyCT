{
  tvct.bsc.pas - bindings for the libbsc entropy coder (QLFC).

  libbsc is Apache-2.0, by the same author as libsais. Only its coder is used:
  bsc_coder_compress/decompress take the BWT output and apply their own RLE,
  MTF and quantized-local-frequency arithmetic coding, which measured 15 %
  smaller than this project's static MTF + rANS on text at comparable speed.

  Source: third_party/libbsc/src (unmodified, see third_party/libbsc/LICENSE).
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
  BSC_CODER_FAST = 3;
  BSC_CODER_STATIC = 1;
  BSC_CODER_ADAPTIVE = 2;

function bsc_coder_init(features: Int32): Int32; cdecl; external name 'bsc_coder_init';
function bsc_coder_compress(input, output: PByte; n, coder, features: Int32): Int32;
  cdecl; external name 'bsc_coder_compress';
function bsc_coder_decompress(input, output: PByte; coder, features: Int32): Int32;
  cdecl; external name 'bsc_coder_decompress';

{ Decompress with the input and output sizes the caller knows: the coder
  validates its own block table instead of trusting the stream. }
function bsc_coder_decompress_bounded(input: PByte; InputSize: Int32;
  output: PByte; OutputSize: Int32; coder, features: Int32): Int32;
  cdecl; external name 'bsc_coder_decompress_bounded';

implementation

end.
