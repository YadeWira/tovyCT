program test_sais;

{ Correctness and speed tests for tvct.sais. }

{$mode objfpc}{$H+}
{$POINTERMATH ON}
{$R-}{$Q-}

uses
  Classes, SysUtils, DateUtils, tvct.sais;
{$I tvct.wincrt.inc}

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const What: string);
begin
  if not Cond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', What);
  end;
end;

function SuffixLess(const T: PByte; N: SizeInt; a, b: SizeInt): Boolean;
var
  k: SizeInt;
begin
  k := 0;
  while (a + k < N) and (b + k < N) do
  begin
    if T[a + k] <> T[b + k] then
      Exit(T[a + k] < T[b + k]);
    Inc(k);
  end;
  Result := (a + k >= N) and (b + k < N);
end;

{ Reference, only for short strings. }
procedure NaiveSA(const T: PByte; N: SizeInt; SA: PInt32);
var
  i, j: SizeInt;
  Swap: Int32;
begin
  for i := 0 to N - 1 do
    SA[i] := Int32(i);
  for i := 1 to N - 1 do
  begin
    j := i;
    while (j > 0) and SuffixLess(T, N, SA[j], SA[j - 1]) do
    begin
      Swap := SA[j - 1]; SA[j - 1] := SA[j]; SA[j] := Swap;
      Dec(j);
    end;
  end;
end;

function ValidateSA(const T: PByte; N: SizeInt; SA: PInt32): Boolean;
{ O(n) check: SA is a permutation and adjacent suffixes are ordered. }
var
  Rank: PInt32;
  i, a, b: SizeInt;
  Ok: Boolean;
begin
  Result := False;
  GetMem(Rank, (N + 1) * SizeOf(Int32));
  try
    for i := 0 to N - 1 do
      Rank[i] := -1;
    Ok := True;
    for i := 0 to N - 1 do
    begin
      if (SA[i] < 0) or (SA[i] >= N) or (Rank[SA[i]] <> -1) then
      begin
        Ok := False;
        Break;
      end;
      Rank[SA[i]] := Int32(i);
    end;
    if Ok then
    begin
      Rank[N] := -1; { the empty suffix is the smallest }
      for i := 0 to N - 2 do
      begin
        a := SA[i];
        b := SA[i + 1];
        if T[a] > T[b] then
          Ok := False
        else if (T[a] = T[b]) and (Rank[a + 1] >= Rank[b + 1]) then
          Ok := False;
        if not Ok then
          Break;
      end;
    end;
    Result := Ok;
  finally
    FreeMem(Rank);
  end;
end;

procedure TestRandom;
var
  Trial, N, i, Alpha: Integer;
  T: array[0..64] of Byte;
  SA, Ref: array[0..64] of Int32;
  Seed: LongWord;
begin
  Seed := 12345;
  for Trial := 0 to 4000 do
  begin
    N := Trial mod 65;
    Alpha := 2 + (Trial mod 3) * 100;   { 2, 102, 202 symbols }
    for i := 0 to N - 1 do
    begin
      Seed := Seed * 1103515245 + 12345;
      T[i] := Byte((Seed shr 16) mod LongWord(Alpha));
    end;
    if N > 1 then
    begin
      { lift the alphabet above zero so the sentinel stays unique }
      for i := 0 to N - 1 do
        T[i] := T[i] + 1;
    end;
    NaiveSA(@T[0], N, @Ref[0]);
    if N > 0 then
    begin
      FillChar(SA, SizeOf(SA), 0);
      SaisBuildSA(@T[0], N, @SA[0]);
      if not CompareMem(@SA[0], @Ref[0], N * SizeOf(Int32)) then
      begin
        Inc(Failures);
        if Failures < 10 then
          WriteLn('FAIL: random trial ', Trial, ' n=', N);
      end;
    end;
  end;
  WriteLn('random: 4001 cases');
end;

procedure TestPatterns;
const
  Pats: array[0..5] of string = ('aaaaaaaaaaaa', 'abababababab', 'abcabcabcabc',
                                 'abacabadabac', 'banana', 'mississippi');
var
  i, k, N: Integer;
  T: array[0..64] of Byte;
  SA, Ref: array[0..64] of Int32;
  s: string;
begin
  for k := 0 to High(Pats) do
  begin
    s := Pats[k];
    N := Length(s);
    for i := 0 to N - 1 do
      T[i] := Byte(s[i + 1]);
    NaiveSA(@T[0], N, @Ref[0]);
    SaisBuildSA(@T[0], N, @SA[0]);
    Check(CompareMem(@SA[0], @Ref[0], N * SizeOf(Int32)), Pats[k]);
  end;
  WriteLn('patterns: done');
end;

procedure BenchFile(const Path: string);
var
  f: TFileStream;
  Total: SizeInt;
  Buf: PByte;
  SA: PInt32;
  BlockSizes: array[0..6] of SizeInt = (64 shl 10, 256 shl 10, 512 shl 10, 1 shl 20, 4 shl 20, 8 shl 20, 16 shl 20);
  b, off, Len: SizeInt;
  t0: TDateTime;
  Secs, MBps: Double;
begin
  f := TFileStream.Create(Path, fmOpenRead);
  try
    Total := f.Size;
    GetMem(Buf, Total);
    GetMem(SA, (Total + 1) * SizeOf(Int32));
    f.ReadBuffer(Buf^, Total);
    for b := 0 to High(BlockSizes) do
    begin
      if BlockSizes[b] > Total then
        Continue;
      off := 0;
      t0 := Now;
      while off + BlockSizes[b] <= Total do
      begin
        Len := BlockSizes[b];
        SaisBuildSA(Buf + off, Len, SA);
        Inc(off, Len);
      end;
      Secs := (Now - t0) * SecsPerDay;
      if Secs <= 0 then
        Secs := 1e-9;
      MBps := (off / 1e6) / Secs;
      WriteLn(Format('  block %4d KB: %6.1f MB/s  (%d MB processed)',
        [BlockSizes[b] shr 10, MBps, off shr 20]));
      { spot-check the last block }
      Check(ValidateSA(Buf + off - BlockSizes[b], BlockSizes[b], SA), 'validate');
    end;
  finally
    FreeMem(SA);
    FreeMem(Buf);
    f.Free;
  end;
end;

begin
  WriteLn('SA-IS test (FPC ', {$I %FPCVERSION%}, ')');
{$IFDEF TVCT_LIBSAIS}
  { This test exercises the Pascal implementation, so force it even when the
    optional C accelerator is linked. }
  SaisForcePascal := True;
  WriteLn('libsais linked, testing the Pascal path');
{$ENDIF}
  TestRandom;
  TestPatterns;
  if ParamCount >= 1 then
  begin
    WriteLn('benchmark on ', ParamStr(1));
    BenchFile(ParamStr(1));
  end;
  if Failures = 0 then
    WriteLn('ALL OK')
  else
  begin
    WriteLn(Failures, ' FAILURES');
    Halt(1);
  end;
end.
