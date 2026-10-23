{
  tvct.lzp.pas - LZP prefilter.

  A hash of the four bytes before the current position predicts where the same
  four bytes were seen last. If the bytes that follow match, a short match is
  emitted; otherwise the byte goes out as a literal. On text this removes the
  repeated phrases that the BWT would otherwise turn into expensive short runs.

  Stream format: literals are copied as they are, except 255, which is written
  as 255 0. A match is written as 255 (length - LZP_MIN + 1), so lengths from
  LZP_MIN to LZP_MIN + 254 are one escape pair.

  The table is updated for every covered position on both sides, which keeps
  encoder and decoder in lockstep.
}
unit tvct.lzp;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

const
  LZP_MIN = 4;
  LZP_MAX = LZP_MIN + 254;
  LZP_ESC = 255;
  LZP_HASH_LOG = 22;

{ Worst case output is twice the input (every byte an escaped literal). }
function LzpBound(N: Int32): Int32; inline;

{ Returns the number of bytes written, or -1 if it does not fit in DstCap. }
function LzpEncode(const Src: PByte; N: Int32; Dst: PByte; DstCap: Int32): Int32;

{ Rebuilds N bytes into Dst. SrcLen is the compressed length. }
function LzpDecode(const Src: PByte; SrcLen, N: Int32; Dst: PByte): Boolean;

implementation

function LzpBound(N: Int32): Int32; inline;
begin
  Result := N * 2 + 16;
end;

function Hash4(const P: PByte): LongWord; inline;
var
  v: LongWord;
begin
  v := LongWord(P[0]) or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or
       (LongWord(P[3]) shl 24);
  { 32-bit wrapping multiply, then keep the top LZP_HASH_LOG bits. }
  v := v * LongWord(2654435761);
  Result := v shr (32 - LZP_HASH_LOG);
end;

function MatchLen(const A, B: PByte; Max: Int32): Int32; inline;
var
  i: Int32;
  x, y: QWord;
begin
  i := 0;
  while i + 8 <= Max do
  begin
    Move(A[i], x, 8);
    Move(B[i], y, 8);
    x := x xor y;
    if x <> 0 then
      Exit(i + (Int32(BsfQWord(x)) shr 3));
    Inc(i, 8);
  end;
  while (i < Max) and (A[i] = B[i]) do
    Inc(i);
  Result := i;
end;

function LzpEncode(const Src: PByte; N: Int32; Dst: PByte; DstCap: Int32): Int32;
var
  Tab: PInt32;
  i, o, h, pred, p, L, MaxL, j: Int32;
begin
  if N <= 4 then
  begin
    if N > DstCap then
      Exit(-1);
    Move(Src[0], Dst[0], N);
    Exit(N);
  end;

  Tab := GetMem((SizeInt(1) shl LZP_HASH_LOG) * SizeOf(Int32));
  FillChar(Tab[0], (SizeInt(1) shl LZP_HASH_LOG) * SizeOf(Int32), 0);
  try
    Move(Src[0], Dst[0], 4);
    o := 4;
    i := 4;
    while i < N do
    begin
      h := Hash4(@Src[i - 4]);
      pred := Tab[h];
      L := 0;
      if pred > 0 then
      begin
        p := pred - 1;
        MaxL := N - i;
        if MaxL > LZP_MAX then
          MaxL := LZP_MAX;
        if p < i then
          L := MatchLen(@Src[p], @Src[i], MaxL);
      end;
      if L >= LZP_MIN then
      begin
        if o + 2 > DstCap then
          Exit(-1);
        Dst[o] := LZP_ESC;
        Dst[o + 1] := Byte(L - LZP_MIN + 1);
        Inc(o, 2);
        for j := 0 to L - 1 do
          Tab[Hash4(@Src[i + j - 4])] := i + j + 1;
        Inc(i, L);
      end
      else
      begin
        if o + 2 > DstCap then
          Exit(-1);
        if Src[i] = LZP_ESC then
        begin
          Dst[o] := LZP_ESC;
          Dst[o + 1] := 0;
          Inc(o, 2);
        end
        else
        begin
          Dst[o] := Src[i];
          Inc(o);
        end;
        Tab[h] := i + 1;
        Inc(i);
      end;
    end;
    Result := o;
  finally
    FreeMem(Tab);
  end;
end;

function LzpDecode(const Src: PByte; SrcLen, N: Int32; Dst: PByte): Boolean;
var
  Tab: PInt32;
  i, o, b, pred, p, L, j: Int32;
begin
  if N <= 4 then
  begin
    if SrcLen < N then
      Exit(False);
    Move(Src[0], Dst[0], N);
    Exit(True);
  end;

  Tab := GetMem((SizeInt(1) shl LZP_HASH_LOG) * SizeOf(Int32));
  FillChar(Tab[0], (SizeInt(1) shl LZP_HASH_LOG) * SizeOf(Int32), 0);
  try
    Move(Src[0], Dst[0], 4);
    i := 4;
    o := 4;
    while o < N do
    begin
      if i >= SrcLen then
        Exit(False);
      b := Src[i];
      Inc(i);
      if b = LZP_ESC then
      begin
        if i >= SrcLen then
          Exit(False);
        b := Src[i];
        Inc(i);
        if b = 0 then
        begin
          Dst[o] := LZP_ESC;
          Tab[Hash4(@Dst[o - 4])] := o + 1;
          Inc(o);
        end
        else
        begin
          L := b + LZP_MIN - 1;
          if o + L > N then
            Exit(False);
          pred := Tab[Hash4(@Dst[o - 4])];
          if pred = 0 then
            Exit(False);
          p := pred - 1;
          if p >= o then
            Exit(False);
          for j := 0 to L - 1 do
            Dst[o + j] := Dst[p + j];
          for j := 0 to L - 1 do
            Tab[Hash4(@Dst[o + j - 4])] := o + j + 1;
          Inc(o, L);
        end;
      end
      else
      begin
        Dst[o] := Byte(b);
        Tab[Hash4(@Dst[o - 4])] := o + 1;
        Inc(o);
      end;
    end;
    Result := True;
  finally
    FreeMem(Tab);
  end;
end;

end.
