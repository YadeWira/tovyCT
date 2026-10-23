{
  tvct.bwt.pas - Burrows-Wheeler transform and its inverse.

  Convention (the one libsais and bzip2-family compressors use): the block is
  treated as the string S followed by one implicit sentinel that is smaller than
  every byte. The forward transform returns N bytes, with the sentinel row
  removed, plus the primary index: the position where that row was, which is
  also where the decoder must put the sentinel back.

  The forward transform is computed from the suffix array of S, so it does not
  depend on how that array was built.
}
unit tvct.bwt;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

{ Bwt[0..N-1] receives the transform of T[0..N-1]; Primary is the index of the
  removed sentinel row. Bwt must have room for N+1 bytes: the sentinel row is
  written one past the end before it is removed. SA is not modified. }
procedure BwtForward(const T: PByte; N: Int32; const SA: PInt32; Bwt: PByte;
  out Primary: Int32);

{ Rebuilds the original block from Bwt[0..N-1] and Primary. Dst may not overlap
  Bwt. }
procedure BwtInverse(const Bwt: PByte; N: Int32; Primary: Int32; Dst: PByte);

implementation

procedure BwtForward(const T: PByte; N: Int32; const SA: PInt32; Bwt: PByte;
  out Primary: Int32);
var
  k, a: Int32;
begin
  { Row 0 of the sentinel-extended BWT holds the predecessor of the sentinel,
    which is the last byte of the block. }
  Bwt[0] := T[N - 1];
  Primary := 1;
  for k := 0 to N - 1 do
  begin
    a := SA[k];
    if a = 0 then
      Primary := k + 1
    else
      Bwt[k + 1] := T[a - 1];
  end;
  { Drop the sentinel row. }
  Move(Bwt[Primary + 1], Bwt[Primary], (N - Primary) * SizeOf(Byte));
end;

procedure BwtInverse(const Bwt: PByte; N: Int32; Primary: Int32; Dst: PByte);
var
  LF: PInt32;
  Cnt, C, Rank: array[0..256] of Int32;
  i, row, k, sym, sum, b: Int32;
begin
  if N <= 0 then
    Exit;

  GetMem(LF, (N + 1) * SizeOf(Int32));
  try
    { Symbol 0 is the sentinel; byte b is symbol b + 1. }
    FillChar(Cnt, SizeOf(Cnt), 0);
    Inc(Cnt[0]);
    for i := 0 to N - 1 do
      Inc(Cnt[Bwt[i] + 1]);

    sum := 0;
    for i := 0 to 256 do
    begin
      C[i] := sum;
      Inc(sum, Cnt[i]);
    end;

    FillChar(Rank, SizeOf(Rank), 0);
    for i := 0 to N do
    begin
      if i = Primary then
        sym := 0
      else
      begin
        if i > Primary then
          b := Bwt[i - 1]
        else
          b := Bwt[i];
        sym := b + 1;
      end;
      LF[i] := C[sym] + Rank[sym];
      Inc(Rank[sym]);
    end;

    { Walk the LF chain from the row that starts with the sentinel. The text
      comes out backwards, one symbol per step; the sentinel itself is never
      written. }
    row := 0;
    for k := N - 1 downto 0 do
    begin
      if row = Primary then
        Dst[k] := 0
      else if row > Primary then
        Dst[k] := Bwt[row - 1]
      else
        Dst[k] := Bwt[row];
      row := LF[row];
    end;
  finally
    FreeMem(LF);
  end;
end;

end.
