{
  tvct.rans.pas - range Asymmetric Numeral Systems coder, static tables.

  One 32-bit state, 12-bit precision, byte renormalisation, with per-context
  frequency tables. The context of a symbol is chosen by the previous symbol
  through a caller-supplied table: the MTF/RLE stream needs at least three
  (after a rank, after RUNA, after RUNB), which is worth about 9 % of the
  compressed size on text.

  The encoder walks the symbols backwards and emits bytes into a buffer from its
  end, so the decoder can read them forwards without a final reversal.
}
unit tvct.rans;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

const
  RANS_PRECISION = 12;
  RANS_TOT = 1 shl RANS_PRECISION;      { 4096 }
  RANS_L = 1 shl 23;

{ Normalises Counts[0..K-1] into Freq[0..K-1] summing to RANS_TOT and writes the
  cumulative starts into Start. Symbols with a zero count get frequency 0. }
procedure RansNormalise(const Counts: PInt32; K: Int32; Freq, Start: PInt32);

function RansBound(N: Int32): Int32; inline;

{ Symbol i uses context CtxTab[previous symbol], with the previous symbol of the
  first one taken as 0. Freq and Start are indexed [ctx * K + symbol]. }
function RansEncodeCtx(const Syms: PWord; N, K, NCtx: Int32; const CtxTab: PByte;
  const Freq, Start: PInt32; Dst: PByte): Int32;

function RansDecodeCtx(const Src: PByte; SrcLen, K, NCtx, N: Int32;
  const CtxTab: PByte; const Freq: PInt32; Syms: PWord): Boolean;

{ Single-context convenience wrappers, used by the unit tests. }
function RansEncode(const Syms: PWord; N: Int32; const Freq, Start: PInt32;
  Dst: PByte): Int32;
function RansDecode(const Src: PByte; SrcLen: Int32; const Freq: PInt32;
  K, N: Int32; Syms: PWord): Boolean;

implementation

procedure RansNormalise(const Counts: PInt32; K: Int32; Freq, Start: PInt32);
var
  i, total, sum, maxi: Int32;
  v: Int64;
begin
  total := 0;
  for i := 0 to K - 1 do
    Inc(total, Counts[i]);

  if total = 0 then
  begin
    FillChar(Freq[0], K * SizeOf(Int32), 0);
    FillChar(Start[0], K * SizeOf(Int32), 0);
    Exit;
  end;

  sum := 0;
  for i := 0 to K - 1 do
  begin
    if Counts[i] = 0 then
      Freq[i] := 0
    else
    begin
      v := (Int64(Counts[i]) * RANS_TOT + total div 2) div total;
      if v < 1 then
        v := 1;
      Freq[i] := Int32(v);
      Inc(sum, Freq[i]);
    end;
  end;

  while sum > RANS_TOT do
  begin
    maxi := -1;
    for i := 0 to K - 1 do
      if (Freq[i] > 1) and ((maxi < 0) or (Freq[i] > Freq[maxi])) then
        maxi := i;
    if maxi < 0 then
      Break;
    Dec(Freq[maxi]);
    Dec(sum);
  end;
  while sum < RANS_TOT do
  begin
    maxi := 0;
    for i := 1 to K - 1 do
      if Freq[i] > Freq[maxi] then
        maxi := i;
    Inc(Freq[maxi]);
    Inc(sum);
  end;

  sum := 0;
  for i := 0 to K - 1 do
  begin
    Start[i] := sum;
    Inc(sum, Freq[i]);
  end;
end;

function RansBound(N: Int32): Int32; inline;
begin
  Result := N * 2 + 16;
end;

function RansEncodeCtx(const Syms: PWord; N, K, NCtx: Int32; const CtxTab: PByte;
  const Freq, Start: PInt32; Dst: PByte): Int32;
var
  state, x, xmax, f, c, s, ctx: LongWord;
  ptr, i, j, cap: Int32;
begin
  cap := RansBound(N);
  ptr := cap;
  state := RANS_L;
  { The context of symbol i comes from symbol i-1, which in this backwards walk
    is the next iteration's symbol. }
  for i := N - 1 downto 0 do
  begin
    if i = 0 then
      ctx := CtxTab[0]
    else
      ctx := CtxTab[Syms[i - 1]];
    s := Syms[i];
    f := LongWord(Freq[Int32(ctx) * K + Int32(s)]);
    c := LongWord(Start[Int32(ctx) * K + Int32(s)]);
    if f = 0 then
      Exit(-1);
    x := state;
    xmax := LongWord(((Int64(RANS_L) shr RANS_PRECISION) shl 8) * Int64(f));
    while x >= xmax do
    begin
      if ptr <= 0 then
        Exit(-1);
      Dec(ptr);
      Dst[ptr] := Byte(x);
      x := x shr 8;
    end;
    state := ((x div f) shl RANS_PRECISION) + (x mod f) + c;
  end;
  { The four state bytes must end up little-endian at the front of the stream. }
  for j := 0 to 3 do
  begin
    if ptr <= 0 then
      Exit(-1);
    Dec(ptr);
    Dst[ptr] := Byte(state shr (24 - 8 * j));
  end;
  if ptr > 0 then
    Move(Dst[ptr], Dst[0], cap - ptr);
  Result := cap - ptr;
end;

function RansDecodeCtx(const Src: PByte; SrcLen, K, NCtx, N: Int32;
  const CtxTab: PByte; const Freq: PInt32; Syms: PWord): Boolean;
var
  Table: array of Word;
  Start: array of Int32;
  state, slot, f, ctx: LongWord;
  ptr, i, s, sum, c, base: Int32;
begin
  if SrcLen < 4 then
    Exit(False);

  { Each context has its own 0..RANS_TOT-1 slot space. }
  SetLength(Start, NCtx * K);
  for c := 0 to NCtx - 1 do
  begin
    sum := 0;
    for s := 0 to K - 1 do
    begin
      Start[c * K + s] := sum;
      Inc(sum, Freq[c * K + s]);
    end;
    if sum <> RANS_TOT then
      Exit(False);
  end;

  SetLength(Table, NCtx * RANS_TOT);
  for c := 0 to NCtx - 1 do
    for s := 0 to K - 1 do
    begin
      base := c * K + s;
      for i := 0 to Freq[base] - 1 do
        Table[c * RANS_TOT + Start[base] + i] := Word(s);
    end;

  state := LongWord(Src[0]) or (LongWord(Src[1]) shl 8) or
           (LongWord(Src[2]) shl 16) or (LongWord(Src[3]) shl 24);
  ptr := 4;
  ctx := CtxTab[0];
  for i := 0 to N - 1 do
  begin
    slot := state and (RANS_TOT - 1);
    s := Table[Int32(ctx) * RANS_TOT + Int32(slot)];
    Syms[i] := Word(s);
    f := LongWord(Freq[Int32(ctx) * K + s]);
    if f = 0 then
      Exit(False);
    state := f * (state shr RANS_PRECISION) + slot - LongWord(Start[Int32(ctx) * K + s]);
    while state < RANS_L do
    begin
      if ptr >= SrcLen then
        Exit(False);
      state := (state shl 8) or LongWord(Src[ptr]);
      Inc(ptr);
    end;
    ctx := CtxTab[s];
  end;
  Result := True;
end;

function RansEncode(const Syms: PWord; N: Int32; const Freq, Start: PInt32;
  Dst: PByte): Int32;
var
  CtxTab: array[0..257] of Byte;
begin
  FillChar(CtxTab, SizeOf(CtxTab), 0);
  Result := RansEncodeCtx(Syms, N, 258, 1, @CtxTab[0], Freq, Start, Dst);
end;

function RansDecode(const Src: PByte; SrcLen: Int32; const Freq: PInt32;
  K, N: Int32; Syms: PWord): Boolean;
var
  CtxTab: array[0..257] of Byte;
begin
  FillChar(CtxTab, SizeOf(CtxTab), 0);
  Result := RansDecodeCtx(Src, SrcLen, K, 1, N, @CtxTab[0], Freq, Syms);
end;

end.
