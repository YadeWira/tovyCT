{
  tvct.codec.pas - stream format v4 and the compress/decompress pipeline.

  Pipeline per block: optional text transform -> BWT -> QLFC (libbsc coder),
  with a stored fallback when the result would not be smaller.

  The BWT is built with libsais through tvct.sais. The entropy stage is libbsc's
  quantized local frequency coder: it does its own RLE, MTF and context-
  conditioned arithmetic coding over the BWT output. The text transform
  (src/c/tvct_text.c) folds capitals and replaces frequent words by short codes
  before the BWT.

  The format is specified in docs/FORMAT.md. In short (integers little-endian,
  varints LEB128):

    stream:  "TVCT" | version 4 | block log | flags | [varint total]
             | blocks | [0 | BLAKE3-128 of the data, when flagged]
    block:   varint orig_size | method | varint body_size | u32 crc
             | u32 body_crc (compressed methods only) | body
    body:    [varint bwt_size, text only] | varint primary
             | [u32 sample rows, if flagged] | QLFC payload

  Blocks are independent: they are compressed and decompressed in batches of
  one per thread, and the output does not depend on the thread count.
}
unit tvct.codec;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, tvct.sais, tvct.bwt, tvct.kernels, tvct.bsc, tvct.crc,
  pjablake3;

const
  CODEC_VERSION = 4;
  DEFAULT_BLOCK_LOG = 23;
  { The coder values libbsc uses for the QLFC variants this format allows. }
  CODER_STATIC = BSC_CODER_STATIC;
  CODER_ADAPTIVE = BSC_CODER_ADAPTIVE;
  SAMPLE_RATE = 4096;

  { Method byte: the coder in bits 0-1, flags above. }
  METHOD_STORED = 0;
  METHOD_FLAG_SAMPLES = 4;
  METHOD_FLAG_TEXT = 8;

  { Text transform: off, on when it makes the block smaller before the BWT, or
    on only when the compressed block comes out smaller (compresses twice). }
  TEXT_OFF = 0;
  TEXT_AUTO = 1;
  TEXT_BEST = 2;

  STREAM_HEADER_MIN = 7;    { magic 4, version, block log, flags }
  STREAM_FLAG_TOTAL = 1;
  STREAM_FLAG_DIGEST = 2;
  DIGEST_SIZE = 16;

type
  TCodecOptions = record
    BlockLog: Int32;
    Coder: Int32;
    UseSamples: Boolean;
    Text: Int32;
    Digest: Boolean;        { BLAKE3-128 of the whole input at the end }
  end;

  TCodecStats = record
    InBytes: Int64;
    OutBytes: Int64;
    Blocks: Integer;
    RawBlocks: Integer;
    TextBlocks: Integer;
  end;

function DefaultOptions: TCodecOptions;

{ Threads <= 1 runs every block on the calling thread. }
function CompressStream(Src, Dst: TStream; const Opts: TCodecOptions;
  Threads: Int32; out Stats: TCodecStats): Boolean;
function DecompressStream(Src, Dst: TStream; Threads: Int32;
  out Stats: TCodecStats): Boolean;

{ The stream header alone. Total is valid only when Known. }
function ReadStreamHeader(Src: TStream; out BlockLog: Int32; out Total: Int64;
  out Known, Digest: Boolean): Boolean;

{ Total uncompressed size of a stream, from the headers without decoding.
  Returns -1 if the stream header is not valid. }
function StreamDataSize(Src: TStream): Int64;

implementation

function tvct_text_encode(const Src: PByte; N: Int32; Dst: PByte;
  Limit: Int32): Int32; cdecl; external name 'tvct_text_encode';
function tvct_text_decode(const Src: PByte; Len: Int32; Dst: PByte;
  N: Int32): Int32; cdecl; external name 'tvct_text_decode';

const
  BLOCK_HEADER_MAX = 5 + 1 + 5 + 4 + 4;
  BODY_PREFIX_MAX = 5 + 5;

type
  TBlockJob = record
    Opts: TCodecOptions;
    Data: PByte;            { compress: the input block; decompress: the output }
    N: Int32;               { size of Data }
    Blk: PByte;             { compress: the serialised block; decompress: the body }
    BlkLen, BlkCap: Int32;
    Method: Int32;
    Index: LongWord;        { position in the stream; seeds the block CRC }
    Crc: LongWord;
    Ok: Boolean;
  end;
  PBlockJob = ^TBlockJob;

  TBlockWorker = class(TThread)
  private
    FJob: PBlockJob;
    FCompress: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AJob: PBlockJob; ACompress: Boolean);
  end;

var
  BscReady: Boolean = False;

function DefaultOptions: TCodecOptions;
begin
  Result.BlockLog := DEFAULT_BLOCK_LOG;
  Result.Coder := CODER_STATIC;
  Result.UseSamples := True;
  Result.Text := TEXT_AUTO;
  Result.Digest := False;
end;

procedure EnsureBsc;
begin
  if not BscReady then
  begin
    bsc_coder_init(0);
    BscReady := True;
  end;
end;

procedure PutU32(P: PByte; V: LongWord); inline;
begin
  P[0] := Byte(V);
  P[1] := Byte(V shr 8);
  P[2] := Byte(V shr 16);
  P[3] := Byte(V shr 24);
end;

function GetU32(P: PByte): LongWord; inline;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or
            (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function PutVarint(P: PByte; V: QWord): Int32;
begin
  Result := 0;
  while V >= $80 do
  begin
    P[Result] := Byte(V) or $80;
    V := V shr 7;
    Inc(Result);
  end;
  P[Result] := Byte(V);
  Inc(Result);
end;

{ Reads a varint of at most MaxBytes from memory. }
function GetVarint(P: PByte; Len: Int32; var Pos: Int32; MaxBytes: Int32;
  out V: QWord): Boolean;
var
  Shift, k: Int32;
  B: Byte;
begin
  Result := False;
  V := 0;
  Shift := 0;
  for k := 1 to MaxBytes do
  begin
    if Pos >= Len then
      Exit;
    B := P[Pos];
    Inc(Pos);
    V := V or (QWord(B and $7F) shl Shift);
    if (B and $80) = 0 then
      Exit(True);
    Inc(Shift, 7);
  end;
end;

{ Same, from a stream; a stream that ends inside it raises. }
function ReadVarint(S: TStream; MaxBytes: Int32; out V: QWord): Boolean;
var
  Shift, k: Int32;
  B: Byte;
begin
  Result := False;
  V := 0;
  Shift := 0;
  for k := 1 to MaxBytes do
  begin
    B := S.ReadByte;
    V := V or (QWord(B and $7F) shl Shift);
    if (B and $80) = 0 then
      Exit(True);
    Inc(Shift, 7);
  end;
end;

procedure ReadExact(S: TStream; P: PByte; N: Int32);
begin
  if N <= 0 then
    Exit;
  if S.Read(P[0], N) <> N then
    raise Exception.Create('unexpected end of stream');
end;

{ A fabricated header must not be able to ask for unbounded memory. Nothing
  real compresses anywhere near this well (16 MiB of zeros, the best case we
  could measure, is 997:1), so a declared size above RATIO_CAP:1 plus a small
  allowance for tiny streams is treated as corruption before any allocation. }
function MaxPlausibleTotal(Remaining: Int64): Int64;
const
  RATIO_CAP = 4096;
  SLACK = 1 shl 20;   { 1 MiB: a 100-byte stream may still declare a large file }
begin
  if Remaining < 0 then
    Remaining := 0;
  Result := (Remaining * RATIO_CAP) + SLACK;
end;

procedure WriteStreamHeader(Dst: TStream; BlockLog: Int32; Total: Int64;
  Known, Digest: Boolean);
var
  Hdr: array[0..STREAM_HEADER_MIN + 9] of Byte;
  Len: Int32;
begin
  Hdr[0] := Ord('T'); Hdr[1] := Ord('V'); Hdr[2] := Ord('C'); Hdr[3] := Ord('T');
  Hdr[4] := CODEC_VERSION;
  Hdr[5] := Byte(BlockLog);
  Hdr[6] := Ord(Known) * STREAM_FLAG_TOTAL + Ord(Digest) * STREAM_FLAG_DIGEST;
  Len := STREAM_HEADER_MIN;
  if Known then
    Inc(Len, PutVarint(@Hdr[Len], QWord(Total)));
  Dst.WriteBuffer(Hdr[0], Len);
end;

function ReadStreamHeader(Src: TStream; out BlockLog: Int32; out Total: Int64;
  out Known, Digest: Boolean): Boolean;
var
  Hdr: array[0..STREAM_HEADER_MIN - 1] of Byte;
  V: QWord;
begin
  Result := False;
  BlockLog := 0;
  Total := 0;
  Known := False;
  Digest := False;
  if Src.Size - Src.Position < STREAM_HEADER_MIN then
    Exit;
  ReadExact(Src, @Hdr[0], STREAM_HEADER_MIN);
  if (Hdr[0] <> Ord('T')) or (Hdr[1] <> Ord('V')) or (Hdr[2] <> Ord('C')) or
     (Hdr[3] <> Ord('T')) or (Hdr[4] <> CODEC_VERSION) then
    Exit;
  BlockLog := Hdr[5];
  if (BlockLog < 16) or (BlockLog > 26) then   { 64 KiB .. 64 MiB }
    Exit;
  if (Hdr[6] and not (STREAM_FLAG_TOTAL or STREAM_FLAG_DIGEST)) <> 0 then
    Exit;
  Known := (Hdr[6] and STREAM_FLAG_TOTAL) <> 0;
  Digest := (Hdr[6] and STREAM_FLAG_DIGEST) <> 0;
  if Known then
  begin
    if not ReadVarint(Src, 9, V) or (V > QWord(High(Int64))) then
      Exit;
    Total := Int64(V);
    if Total > MaxPlausibleTotal(Int64(Src.Size) - Int64(Src.Position)) then
      Exit;
  end;
  Result := True;
end;

{ ---- one block ---- }

{ Builds the LF-chain sample rows: for chunk j, the row of output position
  min((j+1) * SAMPLE_RATE, N) - 1. The row of position p is 1 + InvSA[p], and
  InvSA[p] is simply the index of p while scanning SA, so this stays sequential. }
procedure BuildSamples(const SA: PInt32; N: Int32; Samples: PInt32;
  out NSamples: Int32);
var
  i, p: Int32;
begin
  NSamples := (N + SAMPLE_RATE - 1) div SAMPLE_RATE;
  for i := 0 to NSamples - 1 do
    Samples[i] := 0;
  for i := 0 to N - 1 do
  begin
    p := SA[i];
    if (p > 0) and ((p and (SAMPLE_RATE - 1)) = 0) then
      Samples[(p shr 12) - 1] := 1 + i;
  end;
  { The last chunk ends at the sentinel rotation, which is row 0. }
  if NSamples > 0 then
    Samples[NSamples - 1] := 0;
end;

{ BWT + QLFC of In[0..T) into Body. Returns the body length, or -1. The body
  starts with the BWT size when the input is a text transform of the block. }
function BuildBody(const In_: PByte; T: Int32; IsText: Boolean;
  const Opts: TCodecOptions; Body: PByte; BodyCap: Int32): Int32;
var
  BwtBuf, Payload: PByte;
  SA, Samples: PInt32;
  Primary, NSamples, R, Pos: Int32;
begin
  Result := -1;
  NSamples := 0;
  if Opts.UseSamples then
    NSamples := (T + SAMPLE_RATE - 1) div SAMPLE_RATE;
  GetMem(SA, (T + 1) * SizeOf(Int32));
  GetMem(BwtBuf, T + 1);
  GetMem(Payload, T + 4096);
  GetMem(Samples, (NSamples + 2) * SizeOf(Int32));
  try
{$IFDEF TVCT_LIBSAIS}
    if Opts.UseSamples then
    begin
      { One pass gives the BWT, the primary index and the sample rows. }
      if libsais_bwt_aux(In_, BwtBuf, SA, T, 0, nil, SAMPLE_RATE, Samples) < 0 then
        Exit;
      Primary := Samples[0];
      Move(Samples[1], Samples[0], (NSamples - 1) * SizeOf(Int32));
      Samples[NSamples - 1] := 0;
    end
    else
    begin
      Primary := libsais_bwt(In_, BwtBuf, SA, T, 0, nil);
      if Primary < 0 then
        Exit;
    end;
{$ELSE}
    SaisBuildSA(In_, T, SA);
    BwtForward(In_, T, SA, BwtBuf, Primary);
    if Opts.UseSamples then
      BuildSamples(SA, T, Samples, NSamples);
{$ENDIF}
    R := bsc_coder_compress(BwtBuf, Payload, T, Opts.Coder, 0);
    if R <= 0 then
      Exit;
    if BODY_PREFIX_MAX + NSamples * 4 + R > BodyCap then
      Exit;
    Pos := 0;
    if IsText then
      Inc(Pos, PutVarint(@Body[Pos], QWord(T)));
    Inc(Pos, PutVarint(@Body[Pos], QWord(Primary)));
    if NSamples > 0 then
    begin
      Move(Samples[0], Body[Pos], NSamples * 4);   { little-endian hosts only }
      Inc(Pos, NSamples * 4);
    end;
    Move(Payload[0], Body[Pos], R);
    Result := Pos + R;
  finally
    FreeMem(Samples);
    FreeMem(Payload);
    FreeMem(BwtBuf);
    FreeMem(SA);
  end;
end;

{ Serialises one block of Job.Data into Job.Blk: compressed, with or without
  the text transform, or stored when that would not be smaller. }
procedure EncodeBlock(var Job: TBlockJob);
var
  N, BodyLen, AltLen, T, HdrLen, Method, Limit: Int32;
  Body, Alt, TextBuf, Tmp, Payload: PByte;
  TextUsed: Boolean;
begin
  N := Job.N;
  Job.Crc := Crc32c(Job.Index, Job.Data[0], N);
  GetMem(Body, Job.BlkCap);
  Alt := nil;
  TextBuf := nil;
  try
    TextUsed := False;
    BodyLen := -1;
    if Job.Opts.Text <> TEXT_OFF then
    begin
      GetMem(TextBuf, N);
      { Measured on real files: when the transform removes less than a tenth
        of the block, the dictionary costs more than the BWT gains. The limit
        lets the encoder give up before it writes anything. Below 1 MiB both
        ways are compressed instead (see below), so any gain will do. }
      Limit := N;
      if (Job.Opts.Text = TEXT_AUTO) and (N >= 1 shl 20) then
        Limit := Int32(Int64(N) * 9 div 10) + 1;
      T := tvct_text_encode(Job.Data, N, TextBuf, Limit);
      if T > 0 then
      begin
        BodyLen := BuildBody(TextBuf, T, True, Job.Opts, Body, Job.BlkCap);
        TextUsed := BodyLen > 0;
      end;
    end;
    { Below 1 MiB compressing twice costs milliseconds, and the dictionary is
      a larger share of the block, so auto checks instead of guessing. }
    if (Job.Opts.Text <> TEXT_AUTO) or not TextUsed or (N < 1 shl 20) then
    begin
      GetMem(Alt, Job.BlkCap);
      AltLen := BuildBody(Job.Data, N, False, Job.Opts, Alt, Job.BlkCap);
      if (AltLen > 0) and ((BodyLen <= 0) or (AltLen <= BodyLen)) then
      begin
        Tmp := Body; Body := Alt; Alt := Tmp;
        BodyLen := AltLen;
        TextUsed := False;
      end;
    end;

    { Stored when compression does not pay for its own extra CRC. }
    Payload := Body;
    if (BodyLen <= 0) or (BodyLen + 4 >= N) then
    begin
      Method := METHOD_STORED;
      BodyLen := N;
      Payload := Job.Data;
    end
    else
    begin
      Method := Job.Opts.Coder;
      if Job.Opts.UseSamples then
        Method := Method or METHOD_FLAG_SAMPLES;
      if TextUsed then
        Method := Method or METHOD_FLAG_TEXT;
    end;

    HdrLen := PutVarint(@Job.Blk[0], QWord(N));
    Job.Blk[HdrLen] := Byte(Method);
    Inc(HdrLen);
    Inc(HdrLen, PutVarint(@Job.Blk[HdrLen], QWord(BodyLen)));
    PutU32(@Job.Blk[HdrLen], Job.Crc);
    Inc(HdrLen, 4);
    if Method <> METHOD_STORED then
    begin
      PutU32(@Job.Blk[HdrLen], Crc32c(0, Payload[0], BodyLen));
      Inc(HdrLen, 4);
    end;
    Move(Payload[0], Job.Blk[HdrLen], BodyLen);
    Job.BlkLen := HdrLen + BodyLen;
    Job.Method := Method;
    Job.Ok := True;
  finally
    FreeMem(TextBuf);
    FreeMem(Alt);
    FreeMem(Body);
  end;
end;

{ Decodes the body in Job.Blk into Job.Data (Job.N bytes). Everything that
  indexes a buffer is checked here first: this is where a corrupt stream that
  got past the body CRC ends up. }
function DecodeBlock(var Job: TBlockJob): Boolean;
var
  Pos, T, Primary, NSamples, k, R: Int32;
  V: QWord;
  Samples: PInt32;
  BwtBuf, TextBuf: PByte;
  IsText: Boolean;
begin
  Result := False;
  Pos := 0;
  IsText := (Job.Method and METHOD_FLAG_TEXT) <> 0;
  T := Job.N;
  if IsText then
  begin
    if not GetVarint(Job.Blk, Job.BlkLen, Pos, 5, V) or (V < 1) or
       (V >= QWord(Job.N)) then
      Exit;
    T := Int32(V);
  end;
  if not GetVarint(Job.Blk, Job.BlkLen, Pos, 5, V) or (V > QWord(T)) then
    Exit;
  Primary := Int32(V);
  NSamples := 0;
  if (Job.Method and METHOD_FLAG_SAMPLES) <> 0 then
    NSamples := (T + SAMPLE_RATE - 1) div SAMPLE_RATE;
  if Job.BlkLen - Pos <= NSamples * 4 then   { the payload needs a byte too }
    Exit;

  Samples := nil;
  BwtBuf := nil;
  TextBuf := nil;
  try
    if NSamples > 0 then
    begin
      { Copied out: the rows are not 4-byte aligned inside the body. }
      GetMem(Samples, NSamples * SizeOf(Int32));
      Move(Job.Blk[Pos], Samples[0], NSamples * 4);
      Inc(Pos, NSamples * 4);
      for k := 0 to NSamples - 1 do
        if (Samples[k] < 0) or (Samples[k] > T) then
          Exit;
    end;
    GetMem(BwtBuf, T + 1);
    R := bsc_coder_decompress_bounded(@Job.Blk[Pos], Job.BlkLen - Pos, BwtBuf, T,
                                      Job.Method and 3, 0);
    if R <> T then
      Exit;
    if IsText then
    begin
      GetMem(TextBuf, T);
      kernel_bwt_inverse(BwtBuf, T, Primary, Samples, NSamples, SAMPLE_RATE,
                         TextBuf);
      Result := tvct_text_decode(TextBuf, T, Job.Data, Job.N) = 0;
    end
    else
    begin
      kernel_bwt_inverse(BwtBuf, T, Primary, Samples, NSamples, SAMPLE_RATE,
                         Job.Data);
      Result := True;
    end;
  finally
    FreeMem(TextBuf);
    FreeMem(BwtBuf);
    FreeMem(Samples);
  end;
end;

constructor TBlockWorker.Create(AJob: PBlockJob; ACompress: Boolean);
begin
  FJob := AJob;
  FCompress := ACompress;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TBlockWorker.Execute;
begin
  try
    if FCompress then
      EncodeBlock(FJob^)
    else
      FJob^.Ok := DecodeBlock(FJob^);
  except
    FJob^.Ok := False;
  end;
end;

{ Runs Count jobs: on this thread when there is one, otherwise one thread each. }
procedure RunJobs(var Jobs: array of TBlockJob; Count: Int32; Compress: Boolean;
  const Skip: array of Boolean);
var
  Workers: array of TBlockWorker;
  i: Int32;
begin
  if Count = 1 then
  begin
    if Skip[0] then
      Exit;
    try
      if Compress then
        EncodeBlock(Jobs[0])
      else
        Jobs[0].Ok := DecodeBlock(Jobs[0]);
    except
      Jobs[0].Ok := False;
    end;
    Exit;
  end;
  SetLength(Workers, Count);
  for i := 0 to Count - 1 do
    if not Skip[i] then
      Workers[i] := TBlockWorker.Create(@Jobs[i], Compress)
    else
      Workers[i] := nil;
  for i := 0 to Count - 1 do
    if Workers[i] <> nil then
    begin
      Workers[i].WaitFor;
      Workers[i].Free;
    end;
end;

function BodyCapFor(BlockSize: Int32): Int32;
begin
  Result := BlockSize + (BlockSize div SAMPLE_RATE + 1) * 4 + BODY_PREFIX_MAX + 64;
end;

function ValidOptions(const Opts: TCodecOptions): Boolean;
begin
  Result := (Opts.BlockLog >= 16) and (Opts.BlockLog <= 26) and
            ((Opts.Coder = CODER_STATIC) or (Opts.Coder = CODER_ADAPTIVE)) and
            (Opts.Text >= TEXT_OFF) and (Opts.Text <= TEXT_BEST);
end;

procedure ClearStats(out Stats: TCodecStats);
begin
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  Stats.TextBlocks := 0;
end;

function CompressStream(Src, Dst: TStream; const Opts: TCodecOptions;
  Threads: Int32; out Stats: TCodecStats): Boolean;
var
  Jobs: array of TBlockJob;
  Skip: array of Boolean;
  BlockSize, Count, i: Int32;
  Total, Start: Int64;
  Known: Boolean;
  Index: LongWord;
  Hash: TBlake3;
  Digest: THash16;
  Zero: Byte;
begin
  Result := False;
  ClearStats(Stats);
  if not ValidOptions(Opts) then
    Exit;
  if Threads < 1 then
    Threads := 1;
  EnsureBsc;
  BlockSize := 1 shl Opts.BlockLog;

  Known := False;
  Total := 0;
  try
    Total := Int64(Src.Size) - Int64(Src.Position);
    Known := Total >= 0;
  except
    Known := False;
  end;
  Start := Dst.Position;
  WriteStreamHeader(Dst, Opts.BlockLog, Total, Known, Opts.Digest);
  if Opts.Digest then
    Hash.Init;
  Index := 0;

  SetLength(Jobs, Threads);
  SetLength(Skip, Threads);
  for i := 0 to Threads - 1 do
  begin
    Jobs[i].Opts := Opts;
    Jobs[i].Data := GetMem(BlockSize);
    Jobs[i].BlkCap := BodyCapFor(BlockSize);
    Jobs[i].Blk := GetMem(Jobs[i].BlkCap + BLOCK_HEADER_MAX);
    Skip[i] := False;
  end;
  try
    repeat
      Count := 0;
      while Count < Threads do
      begin
        Jobs[Count].N := Src.Read(Jobs[Count].Data[0], BlockSize);
        if Jobs[Count].N <= 0 then
          Break;
        Jobs[Count].Ok := False;
        Jobs[Count].Index := Index;
        Inc(Index);
        Inc(Count);
      end;
      if Count = 0 then
        Break;
      RunJobs(Jobs, Count, True, Skip);
      for i := 0 to Count - 1 do
      begin
        if not Jobs[i].Ok then
          Exit;
        if Opts.Digest then
          Hash.Update(Jobs[i].Data[0], Jobs[i].N);
        Dst.WriteBuffer(Jobs[i].Blk[0], Jobs[i].BlkLen);
        Inc(Stats.InBytes, Jobs[i].N);
        Inc(Stats.Blocks);
        if Jobs[i].Method = METHOD_STORED then
          Inc(Stats.RawBlocks);
        if (Jobs[i].Method and METHOD_FLAG_TEXT) <> 0 then
          Inc(Stats.TextBlocks);
      end;
    until Count < Threads;
    if Opts.Digest then
    begin
      { A zero original size cannot start a block: it ends the stream. }
      Zero := 0;
      Dst.WriteBuffer(Zero, 1);
      Digest := Hash.Final;
      Dst.WriteBuffer(Digest[0], DIGEST_SIZE);
    end;
    Stats.OutBytes := Dst.Position - Start;
    Result := True;
  finally
    for i := 0 to Threads - 1 do
    begin
      FreeMem(Jobs[i].Data);
      FreeMem(Jobs[i].Blk);
    end;
  end;
end;

{ Reads one block header and its body into Job. Returns False on anything the
  format does not allow; a stream that ends early raises. }
function ReadBlock(Src: TStream; var Job: TBlockJob; AllocSize, BodyCap: Int32): Boolean;
var
  V: QWord;
  Hdr: array[0..7] of Byte;
  Coder: Int32;
begin
  Result := False;
  if not ReadVarint(Src, 5, V) or (V < 1) or (V > QWord(AllocSize)) then
    Exit;
  Job.N := Int32(V);
  Job.Method := Src.ReadByte;
  Coder := Job.Method and 3;
  if (Job.Method and not (3 or METHOD_FLAG_SAMPLES or METHOD_FLAG_TEXT)) <> 0 then
    Exit;
  if (Coder = 3) or ((Coder = METHOD_STORED) and (Job.Method <> METHOD_STORED)) then
    Exit;
  if not ReadVarint(Src, 5, V) or (V < 1) or (V > QWord(BodyCap)) then
    Exit;
  Job.BlkLen := Int32(V);
  if Job.Method = METHOD_STORED then
  begin
    if Job.BlkLen <> Job.N then
      Exit;
    ReadExact(Src, @Hdr[0], 4);
    Job.Crc := GetU32(@Hdr[0]);
    ReadExact(Src, Job.Data, Job.N);
    Result := Crc32c(Job.Index, Job.Data[0], Job.N) = Job.Crc;
    Job.Ok := Result;
  end
  else
  begin
    ReadExact(Src, @Hdr[0], 8);
    Job.Crc := GetU32(@Hdr[0]);
    ReadExact(Src, Job.Blk, Job.BlkLen);
    Result := Crc32c(0, Job.Blk[0], Job.BlkLen) = GetU32(@Hdr[4]);
    Job.Ok := False;
  end;
end;

function DecompressStream(Src, Dst: TStream; Threads: Int32;
  out Stats: TCodecStats): Boolean;
var
  Jobs: array of TBlockJob;
  Skip: array of Boolean;
  BlockLog, AllocSize, BodyCap, Count, i: Int32;
  Total, Decoded, Pending, MaxTotal, Start: Int64;
  Known, HasDigest, Ended: Boolean;
  Index: LongWord;
  Hash: TBlake3;
  Want, Got: THash16;
begin
  Result := False;
  ClearStats(Stats);
  if Threads < 1 then
    Threads := 1;
  EnsureBsc;
  Start := Src.Position;
  if not ReadStreamHeader(Src, BlockLog, Total, Known, HasDigest) then
    Exit;
  if HasDigest then
    Hash.Init;
  Index := 0;
  Ended := False;
  { A fabricated header must not ask for a large allocation. The buffers are
    sized by the declared total when there is one, and in any case by what the
    compressed size could plausibly expand to. Every block is then checked
    against the same bound, so no block can claim more. }
  MaxTotal := MaxPlausibleTotal(Int64(Src.Size) - Int64(Src.Position));
  AllocSize := 1 shl BlockLog;
  if MaxTotal < AllocSize then
    AllocSize := Int32(MaxTotal);
  if Known and (Total < AllocSize) then
    AllocSize := Int32(Total);
  if AllocSize < 1 then
    AllocSize := 1;
  BodyCap := BodyCapFor(AllocSize);
  Decoded := 0;

  SetLength(Jobs, Threads);
  SetLength(Skip, Threads);
  for i := 0 to Threads - 1 do
  begin
    Jobs[i].Data := nil;
    Jobs[i].Blk := nil;
  end;
  try
    for i := 0 to Threads - 1 do
    begin
      Jobs[i].Data := GetMem(AllocSize);
      Jobs[i].Blk := GetMem(BodyCap);
      Jobs[i].BlkCap := BodyCap;
    end;
    repeat
      Count := 0;
      Pending := 0;
      while (Count < Threads) and not Ended and (Src.Position < Src.Size) do
      begin
        if HasDigest and (Src.ReadByte = 0) then
        begin
          Ended := True;
          Break;
        end;
        if HasDigest then
          Src.Seek(-1, soCurrent);
        Jobs[Count].Index := Index;
        Inc(Index);
        if not ReadBlock(Src, Jobs[Count], AllocSize, BodyCap) then
          Exit;
        { The batch is read before any of it is written: check the whole batch
          against the totals before a single byte reaches the destination. }
        Inc(Pending, Jobs[Count].N);
        if Decoded + Pending > MaxTotal then
          Exit;
        if Known and (Decoded + Pending > Total) then
          Exit;
        Skip[Count] := Jobs[Count].Method = METHOD_STORED;
        Inc(Count);
      end;
      if Count = 0 then
        Break;
      RunJobs(Jobs, Count, False, Skip);
      for i := 0 to Count - 1 do
      begin
        if not Jobs[i].Ok then
          Exit;
        if Crc32c(Jobs[i].Index, Jobs[i].Data[0], Jobs[i].N) <> Jobs[i].Crc then
          Exit;
        if HasDigest then
          Hash.Update(Jobs[i].Data[0], Jobs[i].N);
        Dst.WriteBuffer(Jobs[i].Data[0], Jobs[i].N);
        Inc(Stats.OutBytes, Jobs[i].N);
        Inc(Decoded, Jobs[i].N);
        Inc(Stats.Blocks);
        if Jobs[i].Method = METHOD_STORED then
          Inc(Stats.RawBlocks);
        if (Jobs[i].Method and METHOD_FLAG_TEXT) <> 0 then
          Inc(Stats.TextBlocks);
      end;
    until False;
    if Known and (Decoded <> Total) then
      Exit;
    { The digest closes the stream: it must be there, match, and be the end. }
    if HasDigest then
    begin
      if not Ended then
        Exit;
      ReadExact(Src, @Want[0], DIGEST_SIZE);
      Got := Hash.Final;
      if not CompareMem(@Want[0], @Got[0], DIGEST_SIZE) then
        Exit;
      if Src.Position <> Src.Size then
        Exit;
    end;
    Stats.InBytes := Src.Position - Start;
    Result := True;
  finally
    for i := 0 to Threads - 1 do
    begin
      FreeMem(Jobs[i].Data);
      FreeMem(Jobs[i].Blk);
    end;
  end;
end;

function StreamDataSize(Src: TStream): Int64;
var
  BlockLog, Method: Int32;
  Total: Int64;
  Known, HasDigest: Boolean;
  Orig, Body: QWord;
begin
  Result := -1;
  if not ReadStreamHeader(Src, BlockLog, Total, Known, HasDigest) then
    Exit;
  if Known then
    Exit(Total);
  Result := 0;
  while Src.Position < Src.Size do
  begin
    if not ReadVarint(Src, 5, Orig) then
      Exit(-1);
    if HasDigest and (Orig = 0) then
      Exit;                     { the end marker }
    if (Orig < 1) or (Orig > QWord(1) shl BlockLog) then
      Exit(-1);
    Method := Src.ReadByte;
    if not ReadVarint(Src, 5, Body) or (Body < 1) then
      Exit(-1);
    if Method = METHOD_STORED then
    begin
      if Body <> Orig then
        Exit(-1);
      Src.Seek(4 + Int64(Body), soCurrent);
    end
    else
      Src.Seek(8 + Int64(Body), soCurrent);
    Inc(Result, Int64(Orig));
  end;
end;

end.
