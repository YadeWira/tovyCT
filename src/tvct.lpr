program tvct;

{ tovyCT command line.

    tvct c <input> [output] [options] compress
    tvct d <input> [output]           decompress
    tvct t <input>                    verify
    tvct i <input>                    show the stream header

  With no output file the result goes next to the input: "name" becomes
  "name.tvct" and "name.tvct" becomes "name".
}

{$mode objfpc}{$H+}
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, tvct.codec, tvct.host;

{$I tvct.wincrt.inc}

var
  Quiet: Boolean = False;
  Threads: Int32 = -1;   { -1: decide from the CPU count }
  Coder: Int32 = CODER_STATIC;
  NoSamples: Boolean = False;
  TextMode: Int32 = TEXT_AUTO;
  WithDigest: Boolean = False;
  Preset: string = '';
  BlockLogSet: Boolean = False;

procedure Usage;
begin
  WriteLn('usage:');
  WriteLn('  tvct c <input> [output] [-l fast|compact|max] [-b MB] [-T N] [-a] [-s]');
  WriteLn('                         [-x off|auto|best] [-H]');
  WriteLn('                                    compress (default: -l fast)');
  WriteLn('  tvct d <input> [output] [-T N]    decompress');
  WriteLn('  tvct t <input> [-T N]             verify');
  WriteLn('');
  WriteLn('  -T N: worker threads (default: one per CPU, at most 8; -T 1 for one)');
  WriteLn('  -a:   adaptive QLFC (smaller, slower; default is static)');
  WriteLn('  -s:   no sample rows (smaller, slower decode; default keeps them)');
  WriteLn('  -H:   end the stream with a BLAKE3-128 digest of the whole input');
  WriteLn('  -x:   text transform: auto (default: when it removes a tenth of the');
  WriteLn('        block), off, or best (compress both ways, keep the smaller)');
  WriteLn('  -l fast:    static, 8 MiB blocks, sample rows (default)');
  WriteLn('  -l compact: static, 16 MiB blocks, sample rows');
  WriteLn('  -l max:     adaptive, no sample rows, 16 MiB blocks');
  WriteLn('              (32 MiB when the input fits in a single block)');
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

{ Seconds since T0, never zero: Windows' clock ticks every ~15 ms, and FPC
  there raises on a floating-point division by zero. }
function Elapsed(T0: TDateTime): Double;
begin
  Result := (Now - T0) * SecsPerDay;
  if Result < 1e-3 then
    Result := 1e-3;
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
  WriteLn(Format('%s: %s -> %s (%.2f%%), %d blocks (%d raw, %d text), %.1f MB/s',
    [What, HumanBytes(Stats.InBytes), HumanBytes(Stats.OutBytes), Ratio,
     Stats.Blocks, Stats.RawBlocks, Stats.TextBlocks,
     (SpeedBytes / 1e6) / Secs]));
end;

function DoCompress(const InPath, OutPath: string;
  const Opts: TCodecOptions): Boolean;
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
        Result := CompressStream(Src, Dst, Opts, Threads, Stats);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'error: ', E.Message);
          Exit(False);
        end;
      end;
      if Result and not Quiet then
        Report('compressed', Stats, Elapsed(T0), Stats.InBytes);
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
        Result := DecompressStream(Src, Dst, Threads, Stats);
      except
        on E: Exception do
        begin
          WriteLn(StdErr, 'error: ', E.Message);
          Result := False;
        end;
      end;
      if Result and not Quiet then
        Report('decompressed', Stats, Elapsed(T0), Stats.OutBytes);
    finally
      Dst.Free;
    end;
    { A failed decode leaves a prefix of the data, which is worse than no file:
      the caller cannot tell it from a valid shorter stream. }
    if not Result then
      DeleteFile(OutPath);
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
      Result := DecompressStream(Src, Null, Threads, Stats);
      if Result then
        WriteLn(Format('ok: %d blocks, %s, %.1f MB/s', [Stats.Blocks,
          HumanBytes(Stats.OutBytes), (Stats.OutBytes / 1e6) / Elapsed(T0)]))
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
  BlockLog: Int32;
  Total: Int64;
  Known, Digest, Ok: Boolean;
begin
  F := TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite);
  try
    try
      Ok := ReadStreamHeader(F, BlockLog, Total, Known, Digest);
    except
      Ok := False;
    end;
    if not Ok then
    begin
      WriteLn(StdErr, 'not a tovyCT v', CODEC_VERSION, ' stream');
      Exit;
    end;
    WriteLn('format:    tovyCT v', CODEC_VERSION);
    WriteLn('block:     ', HumanBytes(Int64(1) shl BlockLog));
    if Known then
      WriteLn('original:  ', HumanBytes(Total))
    else
      WriteLn('original:  unknown');
    if Digest then
      WriteLn('digest:    BLAKE3-128');
    WriteLn('file size: ', HumanBytes(F.Size));
  finally
    F.Free;
  end;
end;

var
  Cmd, InPath, OutPath: string;
  i, BlockLog, MB: Int32;
  Opts: TCodecOptions;
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
    else if ParamStr(i) = '-a' then
      Coder := CODER_ADAPTIVE
    else if ParamStr(i) = '-s' then
      NoSamples := True
    else if ParamStr(i) = '-H' then
      WithDigest := True
    else if ParamStr(i) = '-x' then
    begin
      Inc(i);
      case LowerCase(ParamStr(i)) of
        'off': TextMode := TEXT_OFF;
        'auto': TextMode := TEXT_AUTO;
        'best': TextMode := TEXT_BEST;
      else
        begin
          Usage;
          Halt(1);
        end;
      end;
    end
    else if ParamStr(i) = '-l' then
    begin
      Inc(i);
      Preset := LowerCase(ParamStr(i));
      if Preset = 'fast' then
      begin
        BlockLog := 23; Coder := CODER_STATIC; NoSamples := False;
        TextMode := TEXT_AUTO;
      end
      else if Preset = 'compact' then
      begin
        BlockLog := 24; Coder := CODER_STATIC; NoSamples := False;
        TextMode := TEXT_AUTO;
      end
      else if Preset = 'max' then
      begin
        BlockLog := 24; Coder := CODER_ADAPTIVE; NoSamples := True;
        TextMode := TEXT_AUTO;
      end
      else
      begin
        Usage;
        Halt(1);
      end;
      BlockLogSet := False;
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
      BlockLogSet := True;
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

  { -l max with no explicit -b: one 32 MiB block when the input fits in one,
    otherwise 16 MiB so the blocks stay independent and parallel. }
  if (Preset = 'max') and (not BlockLogSet) and (Cmd = 'c') then
  begin
    try
      with TFileStream.Create(InPath, fmOpenRead or fmShareDenyWrite) do
      try
        if Size <= Int64(32) * 1024 * 1024 then
          BlockLog := 25
        else
          BlockLog := 24;
      finally
        Free;
      end;
    except
      BlockLog := 24;
    end;
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
        Opts := DefaultOptions;
        Opts.BlockLog := BlockLog;
        Opts.Coder := Coder;
        Opts.UseSamples := not NoSamples;
        Opts.Text := TextMode;
        Opts.Digest := WithDigest;
        Halt(Ord(not DoCompress(InPath, OutPath, Opts)));
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
