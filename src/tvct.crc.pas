{
  tvct.crc.pas - CRC-32C (Castagnoli).

  The loop lives in C (src/c/tvct_crc.c) so it can use the hardware instruction:
  SSE4.2 `crc32` on x86, `crc32cd` on AArch64, and a slicing-by-8 table when the
  CPU does not have it. Both paths produce the same bytes, so the compressed
  stream never depends on which one ran.
}
unit tvct.crc;

{$mode objfpc}{$H+}
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}

interface

function Crc32c(Crc: LongWord; const Data; Len: SizeInt): LongWord;

implementation

function tvct_crc32c(Crc: LongWord; const Data; Len: SizeInt): LongWord;
  cdecl; external name 'tvct_crc32c';

function Crc32c(Crc: LongWord; const Data; Len: SizeInt): LongWord;
begin
  Result := tvct_crc32c(Crc, Data, Len);
end;

end.
