{
  tvct.mtf.pas - move-to-front transform with zero-run coding.

  The BWT output is dominated by long runs of the same symbol, which become
  zeros after the move-to-front step. Those runs are coded as a binary number,
  one bit per token (RUNA for 0, RUNB for 1), most significant bit first, with
  the implicit leading 1 of (run + 1) dropped. A run is therefore self-delimiting:
  the first non-RUN token after it is the next rank.

  The token alphabet is 0..255 for a rank and 256/257 for RUNA/RUNB.
}
unit tvct.mtf;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

const
  MTF_RUNA = 256;
  MTF_RUNB = 257;
  MTF_SYMBOLS = 258;

{ Transforms Bwt[0..N-1] into Tokens[0..N-1]; the token count never exceeds N.
  Returns the number of tokens. Tokens must hold N entries. }
function MtfRleEncode(const Bwt: PByte; N: Int32; Tokens: PWord): Int32;

{ Rebuilds Bwt[0..N-1] from Tokens[0..Count-1]. Returns False on a malformed
  stream (a run longer than the output, or too many tokens for N). }
function MtfRleDecode(const Tokens: PWord; Count, N: Int32; Bwt: PByte): Boolean;

implementation

function MtfRleEncode(const Bwt: PByte; N: Int32; Tokens: PWord): Int32;
var
  List: array[0..255] of Byte;
  i, j, k, b, Run, Count: Int32;
  v, Top: Int32;

  procedure EmitRun(Z: Int32); inline;
  begin
    v := Z + 1;
    Top := 1;
    while (Top shl 1) <= v do
      Top := Top shl 1;
    Top := Top shr 1;
    while Top > 0 do
    begin
      if (v and Top) <> 0 then
        Tokens[Count] := MTF_RUNB
      else
        Tokens[Count] := MTF_RUNA;
      Inc(Count);
      Top := Top shr 1;
    end;
  end;

begin
  for i := 0 to 255 do
    List[i] := Byte(i);
  Count := 0;
  Run := 0;
  for i := 0 to N - 1 do
  begin
    b := Bwt[i];
    j := 0;
    while List[j] <> b do
      Inc(j);
    if j > 0 then
    begin
      Move(List[0], List[1], j);
      List[0] := Byte(b);
    end;
    if j = 0 then
      Inc(Run)
    else
    begin
      if Run > 0 then
      begin
        EmitRun(Run);
        Run := 0;
      end;
      Tokens[Count] := Word(j);
      Inc(Count);
    end;
  end;
  if Run > 0 then
    EmitRun(Run);
  Result := Count;
end;

function MtfRleDecode(const Tokens: PWord; Count, N: Int32; Bwt: PByte): Boolean;
var
  List: array[0..255] of Byte;
  k, i, t, b, Acc, z, j: Int32;
begin
  for i := 0 to 255 do
    List[i] := Byte(i);
  k := 0;
  i := 0;
  while k < Count do
  begin
    t := Tokens[k];
    Inc(k);
    if t >= MTF_RUNA then
    begin
      Acc := 1;
      Acc := Acc * 2 + (t - MTF_RUNA);
      while (k < Count) and (Tokens[k] >= MTF_RUNA) do
      begin
        Acc := Acc * 2 + (Tokens[k] - MTF_RUNA);
        Inc(k);
      end;
      z := Acc - 1;
      if i + z > N then
        Exit(False);
      for j := 1 to z do
      begin
        Bwt[i] := List[0];
        Inc(i);
      end;
    end
    else
    begin
      if i >= N then
        Exit(False);
      b := List[t];
      if t > 0 then
      begin
        Move(List[0], List[1], t);
        List[0] := Byte(b);
      end;
      Bwt[i] := Byte(b);
      Inc(i);
    end;
  end;
  Result := i = N;
end;

end.
