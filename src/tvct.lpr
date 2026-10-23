program tvct;

{ tovyCT command line.

    tvct c <input> [output] [-b MB]   compress
    tvct d <input> [output]           decompress
    tvct t <input>                    verify
    tvct i <input>                    show the stream header

  With no output file the result goes next to the input: "name" becomes
  "name.tvct" and "name.tvct" becomes "name".
}

{$mode objfpc}{$H+}
{$R-}{$Q-}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, tvct.codec, tvct.host;

{$I tvct.wincrt.inc}

var
  Quiet: Boolean = False;
  Threads: Int32 = -1;   { -1: decide from the CPU count }

procedure Usage;
begin
  WriteLn('usage:');
  WriteLn('  tvct c <input> [output] [-b MB] [-T N]   compress (default blocks 8 MB)');
  WriteLn('  tvct d <input> [output] [-T N]    decompress');
  WriteLn('  tvct t <input> [-T N]             verify');
  WriteLn('');
  WriteLn('  -T N: worker threads (default: one per CPU, at most 8; -T 1 for one)');
  WriteLn('  tvct i <input>                    show header');
end;

function DefaultOutput(const Path: string; Compress: Boolean): string;
begin
  if Compress then
    Result := Path + '.tvct'
  else if Copy(Path, Length(Path) - 4, 5) = '.tvct' then
    Result := Copy(Path, 1, Length(Path) - 5)
  else
    Result := Path + '.out';
end;

function HumanBytes(N: Int64): string;
begin
  if N < 1024 then
    Result := Format('%d B', [N])
  else if N < 1024 * 1024 then
    Result := Format('%.1f KiB', [N / 1024])
  else
    Result := Format('%.2f MiB', [N / (1024 * 1024)]);
end;

procedure Report(const What: string; Stats: TCodecStats; Secs: Double;
  SpeedBytes: Int64);
var
  Ratio: Double;
begin
  if Stats.InBytes > 0 then
    Ratio := 100.0 * Stats.OutBytes / Stats.InBytes
  else
    Ratio := 0;
  WriteLn(Format('%s: %s -> %s (%.2f%%), %d blocks (%d raw), %.1f MB/s',
    [What, HumanBytes(Stats.InBytes), HumanBytes(Stats.OutBytes), Ratio,
     Stats.Blocks, Stats.RawBlocks,
     (SpeedBytes / 1e6) / Secs]));
end;

function DoCompress(const InPath, OutPath: string; BlockLog: Int32): Boolean;
var
  Src, Dst: TFileStream;
  Stats: TCodecStats;
  T0: TDateTime;
begin
  Result := False;
  Src := TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(OutPath, fmCreate);
    try
      T0 := Now;
      try
        if Threads > 1 then
          Result := CompressStreamMT(Src, Dst, BlockLog, Threads, Stats)
        else
          Result := CompressStream(Src, Dst, BlockLog, Stats);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'error: ', E.Message);
          Exit(False);
        end;
      end;
      if Result and not Quiet then
        Report('compressed', Stats, (Now - T0) * SecsPerDay, Stats.InBytes);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

function DoDecompress(const InPath, OutPath: string): Boolean;
var
  Src, Dst: TFileStream;
  Stats: TCodecStats;
  T0: TDateTime;
begin
  Result := False;
  Src := TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(OutPath, fmCreate);
    try
      T0 := Now;
      try
        if Threads > 1 then
          Result := DecompressStreamMT(Src, Dst, Threads, Stats)
        else
          Result := DecompressStream(Src, Dst, Stats);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'error: ', E.Message);
          Exit(False);
        end;
      end;
      if Result and not Quiet then
        Report('decompressed', Stats, (Now - T0) * SecsPerDay, Stats.OutBytes);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

function DoTest(const InPath: string): Boolean;
var
  Src: TFileStream;
  Null: TMemoryStream;
  Stats: TCodecStats;
  T0: TDateTime;
begin
  Src := TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite);
  try
    Null := TMemoryStream.Create;
    try
      T0 := Now;
      if Threads > 1 then
        Result := DecompressStreamMT(Src, Null, Threads, Stats)
      else
        Result := DecompressStream(Src, Null, Stats);
      if Result then
        WriteLn(Format('ok: %d blocks, %s, %.1f MB/s', [Stats.Blocks,
          HumanBytes(Stats.OutBytes), (Stats.OutBytes / 1e6) / ((Now - T0) * SecsPerDay)]))
      else
        WriteLn(StdErr, 'corrupt stream');
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'error: ', E.Message);
        Result := False;
      end;
    end;
    Null.Free;
  finally
    Src.Free;
  end;
end;

procedure DoInfo(const InPath: string);
var
  F: TFileStream;
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Size: Int64;
begin
  F := TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite);
  try
    Size := F.Size;
    if Size < CODEC_HEADER_SIZE then
    begin
      WriteLn(StdErr, 'not a tovyCT stream');
      Exit;
    end;
    F.ReadBuffer(Hdr[0], CODEC_HEADER_SIZE);
    if (Hdr[0] <> Ord('T')) or (Hdr[1] <> Ord('V')) or (Hdr[2] <> Ord('C')) or
       (Hdr[3] <> Ord('T')) then
    begin
      WriteLn(StdErr, 'not a tovyCT stream');
      Exit;
    end;
    WriteLn('format:    tovyCT v', Hdr[4]);
    WriteLn('block:     ', (1 shl Hdr[5]) shr 20, ' MiB');
    WriteLn('file size: ', HumanBytes(Size));
  finally
    F.Free;
  end;
end;

var
  Cmd, InPath, OutPath: string;
  i, BlockLog, MB: Int32;
function DefaultThreads: Int32;
begin
  Result := CpuCount;
  if Result > 8 then
    Result := 8;
  if Result < 1 then
    Result := 1;
end;

begin
  if ParamCount < 2 then
  begin
    Usage;
    Halt(1);
  end;

  Cmd := LowerCase(ParamStr(1));
  InPath := ParamStr(2);
  OutPath := '';
  BlockLog := DEFAULT_BLOCK_LOG;

  i := 3;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '-T' then
    begin
      Inc(i);
      Threads := StrToIntDef(ParamStr(i), -1);
      if Threads < 0 then
        Threads := -1;
      if Threads > 64 then
        Threads := 64;
    end
    else if ParamStr(i) = '-b' then
    begin
      Inc(i);
      MB := StrToIntDef(ParamStr(i), 8);
      if (MB < 1) or (MB > 64) then
        MB := 8;
      BlockLog := 20 + Int32(Round(Ln(MB) / Ln(2)));
      if (1 shl BlockLog) <> MB * 1024 * 1024 then
        BlockLog := 23;
    end
    else if OutPath = '' then
      OutPath := ParamStr(i)
    else
    begin
      Usage;
      Halt(1);
    end;
    Inc(i);
  end;

  if Threads < 0 then
    Threads := DefaultThreads;
  if Threads = 0 then
    Threads := CpuCount;

  case Cmd of
    'c':
      begin
        if OutPath = '' then
          OutPath := DefaultOutput(InPath, True);
        Halt(Ord(not DoCompress(InPath, OutPath, BlockLog)));
      end;
    'd':
      begin
        if OutPath = '' then
          OutPath := DefaultOutput(InPath, False);
        Halt(Ord(not DoDecompress(InPath, OutPath)));
      end;
    't':
      Halt(Ord(not DoTest(InPath)));
    'i':
      DoInfo(InPath);
    else
      begin
        Usage;
        Halt(1);
      end;
  end;
end.
