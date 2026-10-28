program test_bwt;

{ Round-trip and speed tests for the BWT, plus the libsais binding when built
  with -dTVCT_LIBSAIS. }

{$mode objfpc}{$H+}
{$POINTERMATH ON}
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}

uses
  Classes, SysUtils, DateUtils, tvct.sais, tvct.bwt;
{$I tvct.wincrt.inc}

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const What: string);
begin
  if not Cond then
  begin
    Inc(Failures);
    if Failures < 10 then
      WriteLn('FAIL: ', What);
  end;
end;

function RoundTripOne(const T: PByte; N: Int32): Boolean;
var
  SA: PInt32;
  B, D: PByte;
  Primary: Int32;
begin
  if N = 0 then
    Exit(True);
  GetMem(SA, (N + 1) * SizeOf(Int32));
  GetMem(B, N + 1);
  GetMem(D, N);
  try
    FillChar(SA[0], (N + 1) * SizeOf(Int32), 0);
    SaisBuildSA(T, N, SA);
    BwtForward(T, N, SA, B, Primary);
    BwtInverse(B, N, Primary, D);
    Result := CompareMem(D, T, N);
  finally
    FreeMem(D);
    FreeMem(B);
    FreeMem(SA);
  end;
end;

procedure TestRandom;
var
  Trial, N, i, Alpha: Integer;
  T: array[0..64] of Byte;
  Seed: LongWord;
  Ok: Boolean;
begin
  Seed := 987654321;
  Ok := True;
  for Trial := 0 to 3000 do
  begin
    N := Trial mod 65;
    Alpha := 2 + (Trial mod 4) * 60;
    for i := 0 to N - 1 do
    begin
      Seed := Seed * 1103515245 + 12345;
      T[i] := Byte((Seed shr 16) mod LongWord(Alpha));
    end;
    if not RoundTripOne(@T[0], N) then
    begin
      Inc(Failures);
      WriteLn('FAIL: random round-trip n=', N);
      Ok := False;
      Break;
    end;
  end;
  if Ok then
    WriteLn('random round-trip: 3001 cases');
end;

procedure TestPatterns;
const
  Pats: array[0..5] of string = ('aaaaaaaaaaaa', 'abababababab', 'abcabcabcabc',
                                 'abacabadabac', 'banana', 'mississippi');
var
  k, i, N: Integer;
  T: array[0..64] of Byte;
begin
  for k := 0 to High(Pats) do
  begin
    N := Length(Pats[k]);
    for i := 0 to N - 1 do
      T[i] := Byte(Pats[k][i + 1]);
    Check(RoundTripOne(@T[0], N), Pats[k]);
  end;
  WriteLn('patterns: done');
end;

procedure BenchFile(const Path: string);
var
  F: TFileStream;
  Total: SizeInt;
  Buf: PByte;
  SA: PInt32;
  B, D: PByte;
  Sizes: array[0..1] of Int32 = (1 shl 20, 8 shl 20);
  si, off: SizeInt;
  N, Primary: Int32;
  t0: TDateTime;
  Secs: Double;
  Ok: Boolean;
begin
  F := TFileStream.Create(Path, fmOpenRead);
  try
    Total := F.Size;
    GetMem(Buf, Total);
    GetMem(SA, (Total + 1) * SizeOf(Int32));
    F.ReadBuffer(Buf^, Total);
    for si := 0 to High(Sizes) do
    begin
      N := Sizes[si];
      if N > Total then
        Continue;
      off := 0;
      Ok := True;
      t0 := Now;
      while off + N <= Total do
      begin
        SaisBuildSA(Buf + off, N, SA);
        Inc(off, N);
      end;
      Secs := (Now - t0) * SecsPerDay;
      WriteLn(Format('  block %d MB: SA      %6.1f MB/s', [N shr 20, off / 1e6 / Secs]));

      getmem(B, N + 1); GetMem(D, N);
      off := 0;
      t0 := Now;
      while off + N <= Total do
      begin
        SaisBuildSA(Buf + off, N, SA);
        BwtForward(Buf + off, N, SA, B, Primary);
        Inc(off, N);
      end;
      Secs := (Now - t0) * SecsPerDay;
      WriteLn(Format('  block %d MB: +BWT    %6.1f MB/s', [N shr 20, off / 1e6 / Secs]));

      off := 0;
      t0 := Now;
      while off + N <= Total do
      begin
        BwtInverse(B, N, Primary, D);
        Inc(off, N);
      end;
      Secs := (Now - t0) * SecsPerDay;
      WriteLn(Format('  block %d MB: inverse %6.1f MB/s', [N shr 20, off / 1e6 / Secs]));

      { verify the last block round-trips }
      off := Total - N;
      SaisBuildSA(Buf + off, N, SA);
      BwtForward(Buf + off, N, SA, B, Primary);
      BwtInverse(B, N, Primary, D);
      Check(CompareMem(D, Buf + off, N), 'file block round-trip');
      FreeMem(D); FreeMem(B);
    end;
  finally
    FreeMem(SA);
    FreeMem(Buf);
    F.Free;
  end;
end;

{$IFDEF TVCT_LIBSAIS}
procedure CompareBackends(const Path: string);
var
  F: TFileStream;
  N: Int32;
  Buf: PByte;
  SA1, SA2: PInt32;
begin
  F := TFileStream.Create(Path, fmOpenRead);
  try
    N := 1 shl 20;
    if F.Size < N then
      N := F.Size;
    GetMem(Buf, N);
    GetMem(SA1, (N + 1) * SizeOf(Int32));
    GetMem(SA2, (N + 1) * SizeOf(Int32));
    F.ReadBuffer(Buf^, N);
    if N < 2 then
    begin
      WriteLn('backend comparison: skipped (input too small)');
      Exit;
    end;
    SaisForcePascal := False;
    SaisBuildSA(Buf, N, SA1);
    SaisForcePascal := True;
    SaisBuildSA(Buf, N, SA2);
    Check(CompareMem(SA1, SA2, N * SizeOf(Int32)), 'libsais and Pascal SA agree');
    SaisForcePascal := False;
    WriteLn('backend comparison: done');
    FreeMem(SA2); FreeMem(SA1); FreeMem(Buf);
  finally
    F.Free;
  end;
end;
{$ENDIF}

begin
  WriteLn('BWT test (FPC ', {$I %FPCVERSION%}, ')');
{$IFDEF TVCT_LIBSAIS}
  WriteLn('libsais: enabled');
{$ELSE}
  WriteLn('libsais: disabled (Pascal SA)');
{$ENDIF}
  TestRandom;
  TestPatterns;
  if ParamCount >= 1 then
  begin
{$IFDEF TVCT_LIBSAIS}
    CompareBackends(ParamStr(1));
{$ENDIF}
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
