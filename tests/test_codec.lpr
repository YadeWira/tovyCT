program test_codec;

{ Stage-by-stage tests for the pipeline units, then a full stream round-trip. }

{$mode objfpc}{$H+}
{$POINTERMATH ON}
{$R-}{$Q-}

uses
  Classes, SysUtils, tvct.codec;

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
  WriteLn('codec stream test');
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
