{
  tvct.api.lpr - shared library with the C ABI (include/tvct.h).

  Buffers are read and written in place: TBufferStream wraps the caller's memory
  and the codec streams through it, so a compress or decompress call does not
  copy the payload. A short write (the destination too small) raises inside the
  codec and is reported as -1.
}
library tvct;

{$mode objfpc}{$H+}
{$R-}{$Q-}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, tvct.codec, tvct.host;

{$I tvct.wincrt.inc}

type
  TBufferStream = class(TStream)
  private
    FBuf: PByte;
    FCap, FLen, FPos: SizeInt;
    FReadOnly: Boolean;
  public
    constructor Create(ABuf: PByte; ACap: SizeInt; AReadOnly: Boolean; ALen: SizeInt);
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    function GetSize: Int64; override;
    property Len: SizeInt read FLen;
  end;

constructor TBufferStream.Create(ABuf: PByte; ACap: SizeInt; AReadOnly: Boolean;
  ALen: SizeInt);
begin
  inherited Create;
  FBuf := ABuf;
  FCap := ACap;
  FReadOnly := AReadOnly;
  FPos := 0;
  if AReadOnly then
    FLen := ALen
  else
    FLen := 0;
end;

function TBufferStream.Read(var Buffer; Count: LongInt): LongInt;
var
  N: SizeInt;
begin
  N := FLen - FPos;
  if Count < N then
    N := Count;
  if N <= 0 then
    Exit(0);
  Move(FBuf[FPos], Buffer, N);
  Inc(FPos, N);
  Result := N;
end;

function TBufferStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  if FReadOnly then
    Exit(0);
  if FPos + Count > FCap then
    Exit(0);
  Move(Buffer, FBuf[FPos], Count);
  Inc(FPos, Count);
  if FPos > FLen then
    FLen := FPos;
  Result := Count;
end;

function TBufferStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  NewPos: Int64;
begin
  case Origin of
    soBeginning: NewPos := Offset;
    soCurrent: NewPos := FPos + Offset;
    soEnd: NewPos := FLen + Offset;
  else
    NewPos := FPos;
  end;
  if NewPos < 0 then
    NewPos := 0;
  FPos := SizeInt(NewPos);
  Result := FPos;
end;

function TBufferStream.GetSize: Int64;
begin
  Result := FLen;
end;

function DefaultThreads: Int32;
begin
  Result := CpuCount;
  if Result > 8 then
    Result := 8;
  if Result < 1 then
    Result := 1;
end;

function tvct_version: PChar; cdecl;
begin
  Result := 'tovyCT 0.2.0 (format v4)';
end;

function tvct_compress_bound(src_size: SizeInt): SizeInt; cdecl;
begin
  Result := src_size + (src_size div 32) + 65536;
end;

function tvct_get_size(src: PByte; src_size: SizeInt): Int64; cdecl;
var
  S: TBufferStream;
begin
  Result := -1;
  S := TBufferStream.Create(src, src_size, True, src_size);
  try
    try
      Result := StreamDataSize(S);
    except
      Result := -1;
    end;
  finally
    S.Free;
  end;
end;

function tvct_compress2(src: PByte; src_size: SizeInt; dst: PByte;
  dst_cap: SizeInt; threads, block_log, coder, no_samples, text,
  digest: Int32): Int64; cdecl;
var
  InS, OutS: TBufferStream;
  St: TCodecStats;
  Opts: TCodecOptions;
begin
  Result := -1;
  if (src_size < 0) or (dst_cap <= 0) then
    Exit;
  InS := TBufferStream.Create(src, src_size, True, src_size);
  OutS := TBufferStream.Create(dst, dst_cap, False, 0);
  try
    if threads <= 0 then
      threads := DefaultThreads;
    if block_log <= 0 then
      block_log := DEFAULT_BLOCK_LOG;
    Opts := DefaultOptions;
    Opts.BlockLog := block_log;
    Opts.Coder := coder;
    Opts.UseSamples := no_samples = 0;
    Opts.Text := text;
    Opts.Digest := digest <> 0;
    try
      if not CompressStream(InS, OutS, Opts, threads, St) then
        Exit;
    except
      Exit;
    end;
    Result := OutS.Len;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

function tvct_compress_ex(src: PByte; src_size: SizeInt; dst: PByte;
  dst_cap: SizeInt; threads, block_log, coder, no_samples: Int32): Int64; cdecl;
begin
  Result := tvct_compress2(src, src_size, dst, dst_cap, threads, block_log,
                           coder, no_samples, TEXT_AUTO, 0);
end;

function tvct_compress(src: PByte; src_size: SizeInt; dst: PByte;
  dst_cap: SizeInt; threads, block_log: Int32): Int64; cdecl;
begin
  Result := tvct_compress2(src, src_size, dst, dst_cap, threads, block_log,
                           CODER_STATIC, 0, TEXT_AUTO, 0);
end;

function tvct_decompress(src: PByte; src_size: SizeInt; dst: PByte;
  dst_cap: SizeInt; threads: Int32): Int64; cdecl;
var
  InS, OutS: TBufferStream;
  St: TCodecStats;
begin
  Result := -1;
  if (src_size <= 0) or (dst_cap <= 0) then
    Exit;
  InS := TBufferStream.Create(src, src_size, True, src_size);
  OutS := TBufferStream.Create(dst, dst_cap, False, 0);
  try
    if threads <= 0 then
      threads := DefaultThreads;
    try
      if not DecompressStream(InS, OutS, threads, St) then
        Exit;
    except
      Exit;
    end;
    Result := OutS.Len;
  finally
    InS.Free;
    OutS.Free;
  end;
end;

exports
  tvct_version,
  tvct_compress_bound,
  tvct_get_size,
  tvct_compress,
  tvct_compress_ex,
  tvct_compress2,
  tvct_decompress;

begin
end.
