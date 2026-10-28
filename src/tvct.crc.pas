{
  tvct.crc.pas - CRC-32C (Castagnoli), table driven.

  The hardware kernels (SSE4.2 crc32, AArch64 crc32) come later; this is the
  portable baseline used to detect a corrupt block.
}
unit tvct.crc;

{$mode objfpc}{$H+}
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}

interface

function Crc32c(Crc: LongWord; const Data; Len: SizeInt): LongWord;

implementation

var
  Table: array[0..255] of LongWord;

procedure InitTable;
var
  i, k: LongWord;
  c: LongWord;
begin
  for i := 0 to 255 do
  begin
    c := i;
    for k := 0 to 7 do
      if (c and 1) <> 0 then
        c := (c shr 1) xor $82F63B78
      else
        c := c shr 1;
    Table[i] := c;
  end;
end;

function Crc32c(Crc: LongWord; const Data; Len: SizeInt): LongWord;
var
  p: PByte;
  i: SizeInt;
begin
  p := @Data;
  Crc := not Crc;
  for i := 0 to Len - 1 do
    Crc := Table[(Crc xor p[i]) and $FF] xor (Crc shr 8);
  Result := not Crc;
end;

initialization
  InitTable;

end.
