program test_codec;

{ Stage-by-stage tests for the pipeline units, then a full stream round-trip. }

{$mode objfpc}{$H+}
{$POINTERMATH ON}
{$R-}{$Q-}

uses
  Classes, SysUtils, tvct.rans, tvct.mtf, tvct.lzp, tvct.bwt, tvct.sais,
  tvct.codec;

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

procedure TestRans;
const
  N = 200000;
  K = 258;
var
  Syms, Back: array of Word;
  Freq, Start, Counts: array[0..K - 1] of Int32;
  Buf: PByte;
  i, Len: Int32;
  Seed: LongWord;
begin
  Seed := 12345;
  SetLength(Syms, N);
  SetLength(Back, N);
  FillChar(Counts, SizeOf(Counts), 0);
  for i := 0 to N - 1 do
  begin
    Seed := Seed * 1103515245 + 12345;
    Syms[i] := Word((Seed shr 16) mod 40);
    Inc(Counts[Syms[i]]);
  end;
  RansNormalise(@Counts[0], K, @Freq[0], @Start[0]);
  GetMem(Buf, RansBound(N));
  Len := RansEncode(@Syms[0], N, @Freq[0], @Start[0], Buf);
  Check(Len > 0, 'rans encode');
  Check(RansDecode(Buf, Len, @Freq[0], K, N, @Back[0]), 'rans decode returns');
  Check(CompareMem(@Syms[0], @Back[0], N * SizeOf(Word)), 'rans round-trip');
  WriteLn('rans: ', Len, ' bytes for ', N, ' symbols');
  FreeMem(Buf);
end;

procedure TestMtf;
var
  Src, Back: PByte;
  Tok: PWord;
  N, Cnt, i, Seed: Int32;
begin
  N := 100000;
  Src := GetMem(N);
  Back := GetMem(N);
  Tok := GetMem(N * SizeOf(Word));
  Seed := 777;
  for i := 0 to N - 1 do
  begin
    Seed := (Seed * 1103515245 + 12345) and $7FFFFFFF;
    if (Seed mod 5) <> 0 then
      Src[i] := Byte(Seed mod 3)      { lots of repeats, like BWT output }
    else
      Src[i] := Byte(Seed mod 256);
  end;
  Cnt := MtfRleEncode(Src, N, Tok);
  Check(MtfRleDecode(Tok, Cnt, N, Back), 'mtf decode returns');
  Check(CompareMem(Src, Back, N), 'mtf round-trip');
  WriteLn('mtf: ', Cnt, ' tokens for ', N, ' bytes');
  FreeMem(Tok); FreeMem(Back); FreeMem(Src);
end;

procedure TestLzp;
const
  Phrase = 'the quick brown fox jumps over the lazy dog. ';
var
  Src, Comp, Back: PByte;
  N, Len, K: Int32;
begin
  N := 1 shl 20;
  Src := GetMem(N);
  Comp := GetMem(LzpBound(N));
  Back := GetMem(N);
  { text-like data: repeated words }
  N := 0;
  while N < 1 shl 20 do
  begin
    K := 1 shl 20 - N;
    if K > Length(Phrase) then
      K := Length(Phrase);
    Move(Phrase[1], Src[N], K);
    Inc(N, K);
  end;
  Len := LzpEncode(Src, N, Comp, LzpBound(N));
  Check(Len > 0, 'lzp encode');
  Check(LzpDecode(Comp, Len, N, Back), 'lzp decode returns');
  Check(CompareMem(Src, Back, N), 'lzp round-trip');
  WriteLn('lzp: ', Len, ' bytes for ', N);
  FreeMem(Back); FreeMem(Comp); FreeMem(Src);
end;

procedure TestStream(const Path: string);
var
  InF, MidF, OutF: TFileStream;
  Stats: TCodecStats;
  Ok: Boolean;
  A, B: TBytes;
  i: Int32;
begin
  InF := TFileStream.Create(Path, fmOpenRead);
  MidF := TFileStream.Create(Path + '.tvct', fmCreate);
  Ok := CompressStream(InF, MidF, 23, Stats);
  MidF.Free;
  InF.Free;
  Check(Ok, 'stream compress');
  WriteLn(Format('stream: %d -> %d bytes (%.2f%%)', [Stats.InBytes, Stats.OutBytes,
    100.0 * Stats.OutBytes / Stats.InBytes]));

  MidF := TFileStream.Create(Path + '.tvct', fmOpenRead);
  OutF := TFileStream.Create(Path + '.rt', fmCreate);
  Ok := DecompressStream(MidF, OutF, Stats);
  OutF.Free;
  MidF.Free;
  Check(Ok, 'stream decompress');
  if Ok then
  begin
    InF := TFileStream.Create(Path, fmOpenRead);
    OutF := TFileStream.Create(Path + '.rt', fmOpenRead);
    Check(InF.Size = OutF.Size, 'round-trip size');
    if InF.Size = OutF.Size then
    begin
      SetLength(A, InF.Size);
      SetLength(B, OutF.Size);
      InF.ReadBuffer(A[0], InF.Size);
      OutF.ReadBuffer(B[0], OutF.Size);
      for i := 0 to High(A) do
        if A[i] <> B[i] then
        begin
          WriteLn(Format('first mismatch at %d: in %d out %d', [i, A[i], B[i]]));
          Break;
        end;
    end;
    InF.Free; OutF.Free;
  end;
end;

begin
  WriteLn('codec stage tests');
  TestRans;
  TestMtf;
  TestLzp;
  if ParamCount >= 1 then
    TestStream(ParamStr(1));
  if Failures = 0 then
    WriteLn('ALL OK')
  else
  begin
    WriteLn(Failures, ' FAILURES');
    Halt(1);
  end;
end.
