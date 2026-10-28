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
{$IFDEF TVCT_CHECKED}{$R+}{$Q+}{$ELSE}{$R-}{$Q-}{$ENDIF}

interface

uses
  Classes, SysUtils, tvct.sais, tvct.bwt, tvct.kernels, tvct.bsc, tvct.crc,
  tvct.guard, pjablake3;

const
  CODEC_VERSION = 4;
  { v5 adds the segmented entropy stage: the BWT output of a block is split
    into K independently coded QLFC streams so the decoder can run them on
    several threads. A v5 stream says so in the version byte; the reader takes
    both. }
  CODEC_VERSION_SEGMENTED = 5;
  DEFAULT_BLOCK_LOG = 23;
  { The coder values libbsc uses for the QLFC variants this format allows. }
  CODER_STATIC = BSC_CODER_STATIC;
  CODER_ADAPTIVE = BSC_CODER_ADAPTIVE;
  SAMPLE_RATE = 4096;
  MAX_SEGMENTS = 8;         { streams per block }
  MIN_SEGMENT_SHIFT = 18;   { 256 KiB: below this a segment does not pay }

  { Method byte: the coder in bits 0-1, flags above. }
  METHOD_STORED = 0;
  METHOD_FLAG_SAMPLES = 4;
  METHOD_FLAG_TEXT = 8;
  METHOD_FLAG_SEGMENTED = 16;

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
    Segments: Int32;        { independent QLFC streams per block, 1 = off }
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
  out Version: Int32;
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
    Threads: Int32;         { how many threads this block may use for itself }
    Index: LongWord;        { position in the stream; seeds the block CRC }
    Crc: LongWord;
    Ok: Boolean;
    { Decode scratch. Kept across the blocks a worker handles: a guard-page
      buffer is a fresh mapping, and mapping one per block costs a page fault
      and a kernel zero-fill for every block. }
    Pay: PByte;             PayCap: SizeInt;
    BwtScratch: PByte;      BwtCap: SizeInt;
    TextScratch: PByte;     TextCap: SizeInt;
    DstScratch: PByte;      DstCap: SizeInt;
    SampleScratch: PInt32;  SampleCap: SizeInt;
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
  Result.Segments := 1;
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
  Known, Digest: Boolean; Version: Int32);
var
  Hdr: array[0..STREAM_HEADER_MIN + 9] of Byte;
  Len: Int32;
begin
  Hdr[0] := Ord('T'); Hdr[1] := Ord('V'); Hdr[2] := Ord('C'); Hdr[3] := Ord('T');
  Hdr[4] := Byte(Version);
  Hdr[5] := Byte(BlockLog);
  Hdr[6] := Ord(Known) * STREAM_FLAG_TOTAL + Ord(Digest) * STREAM_FLAG_DIGEST;
  Len := STREAM_HEADER_MIN;
  if Known then
    Inc(Len, PutVarint(@Hdr[Len], QWord(Total)));
  Dst.WriteBuffer(Hdr[0], Len);
end;

function ReadStreamHeader(Src: TStream; out BlockLog: Int32; out Total: Int64;
  out Version: Int32; out Known, Digest: Boolean): Boolean;
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
     (Hdr[3] <> Ord('T')) or
     ((Hdr[4] <> CODEC_VERSION) and (Hdr[4] <> CODEC_VERSION_SEGMENTED)) then
    Exit;
  Version := Hdr[4];
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
  const Opts: TCodecOptions; Body: PByte; BodyCap: Int32;
  out Segmented: Boolean): Int32;
var
  BwtBuf, Payload: PByte;
  SA, Samples: PInt32;
  Primary, NSamples, R, Pos, K, Seg, Off, Len, Total: Int32;
  SegLen: array[0..MAX_SEGMENTS - 1] of Int32;
begin
  Segmented := False;
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
    { Segmented entropy stage: K independent QLFC streams over the BWT
      output, so the decoder can run them on several threads. Costs 0.04
      points of ratio with two streams and buys up to K times the entropy
      throughput inside one block. }
    K := Opts.Segments;
    if K < 1 then K := 1;
    if K > MAX_SEGMENTS then K := MAX_SEGMENTS;
    if (K > 1) and (T < (1 shl (MIN_SEGMENT_SHIFT + 1))) then
      K := 1;                       { two segments of at least 256 KiB }
    Total := 0;
    if K > 1 then
    begin
      for Seg := 0 to K - 1 do
      begin
        Off := Int32(Int64(T) * Seg div K);
        Len := Int32(Int64(T) * (Seg + 1) div K) - Off;
        R := bsc_coder_compress(BwtBuf + Off, Payload + Total, Len,
                                Opts.Coder, 0);
        if R <= 0 then
          Exit;
        SegLen[Seg] := R;
        Inc(Total, R);
      end;
      Segmented := True;
      R := Total;
    end
    else
    begin
      R := bsc_coder_compress(BwtBuf, Payload, T, Opts.Coder, 0);
      if R <= 0 then
        Exit;
      SegLen[0] := R;
    end;
    if BODY_PREFIX_MAX + NSamples * 4 + MAX_SEGMENTS * 5 + R > BodyCap then
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
    if Segmented then
    begin
      Inc(Pos, PutVarint(@Body[Pos], QWord(K)));
      for Seg := 0 to K - 1 do
        Inc(Pos, PutVarint(@Body[Pos], QWord(SegLen[Seg])));
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
  TextUsed, Segmented, TextSegmented, AltSegmented: Boolean;
begin
  N := Job.N;
  Job.Crc := Crc32c(Job.Index, Job.Data[0], N);
  GetMem(Body, Job.BlkCap);
  Alt := nil;
  TextBuf := nil;
  try
    TextUsed := False;
    Segmented := False;
    TextSegmented := False;
    AltSegmented := False;
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
        BodyLen := BuildBody(TextBuf, T, True, Job.Opts, Body, Job.BlkCap,
                             TextSegmented);
        TextUsed := BodyLen > 0;
        if TextUsed then
          Segmented := TextSegmented;
      end;
    end;
    { Below 1 MiB compressing twice costs milliseconds, and the dictionary is
      a larger share of the block, so auto checks instead of guessing. }
    if (Job.Opts.Text <> TEXT_AUTO) or not TextUsed or (N < 1 shl 20) then
    begin
      GetMem(Alt, Job.BlkCap);
      AltLen := BuildBody(Job.Data, N, False, Job.Opts, Alt, Job.BlkCap,
                          AltSegmented);
      if (AltLen > 0) and ((BodyLen <= 0) or (AltLen <= BodyLen)) then
      begin
        Tmp := Body; Body := Alt; Alt := Tmp;
        BodyLen := AltLen;
        Segmented := AltSegmented;
        TextUsed := False;
      end
      else if BodyLen > 0 then
        Segmented := TextSegmented;
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
      if Segmented then
        Method := Method or METHOD_FLAG_SEGMENTED;
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

{ Grows a guarded scratch buffer when the block needs more room than the last
  one. The capacity is the size the buffer was mapped with. }
function NeedGuard(var P: Pointer; var Cap: SizeInt; Need: SizeInt): Boolean;
begin
  if Cap >= Need then
    Exit(P <> nil);
  if P <> nil then
    GuardFree(P, Cap);
  P := GuardAlloc(Need);
  Cap := Need;
  Result := P <> nil;
end;

procedure FreeScratch(var Job: TBlockJob);
begin
  if Job.Pay <> nil then GuardFree(Job.Pay, Job.PayCap);
  if Job.BwtScratch <> nil then GuardFree(Job.BwtScratch, Job.BwtCap);
  if Job.TextScratch <> nil then GuardFree(Job.TextScratch, Job.TextCap);
  if Job.DstScratch <> nil then GuardFree(Job.DstScratch, Job.DstCap);
  if Job.SampleScratch <> nil then GuardFree(Job.SampleScratch, Job.SampleCap);
  Job.Pay := nil; Job.PayCap := 0;
  Job.BwtScratch := nil; Job.BwtCap := 0;
  Job.TextScratch := nil; Job.TextCap := 0;
  Job.DstScratch := nil; Job.DstCap := 0;
  Job.SampleScratch := nil; Job.SampleCap := 0;
end;

{ Decodes the body in Job.Blk into Job.Data (Job.N bytes). Everything that
  indexes a buffer is checked here first: this is where a corrupt stream that
  got past the body CRC ends up. }
type
  { Everything the guarded stages need. Allocated outside GuardRun, so the
    buffers can be freed however the run ends. }
  TSegDecode = record
    Pay: PByte;
    PayLen: Int32;
    Dst: PByte;
    DstLen: Int32;
    Coder: Int32;
    Ok: Boolean;
  end;

  TSegThread = class(TThread)
  private
    FCtx: ^TSegDecode;
  protected
    procedure Execute; override;
  public
    constructor Create(ACtx: Pointer);
  end;

  TGuardDecode = record
    Pay: PByte;
    PayLen: Int32;
    Bwt: PByte;
    T, Primary: Int32;
    Samples: PInt32;
    NSamples: Int32;
    Text: PByte;
    Dst: PByte;
    N: Int32;
    Coder: Int32;
    R: Int32;
    Ok: Boolean;
  end;

{ One entropy segment, decoded inside the sandbox. }
procedure GuardEntropyOne(Ctx: Pointer); cdecl;
var
  C: ^TSegDecode;
begin
  C := Ctx;
  C^.Ok := bsc_coder_decompress_bounded(C^.Pay, C^.PayLen, C^.Dst, C^.DstLen,
                                         C^.Coder, 0) = C^.DstLen;
end;

{ The tail of a block: inverse BWT, then the inverse text transform. }
procedure GuardTail(Ctx: Pointer); cdecl;
var
  C: ^TGuardDecode;
begin
  C := Ctx;
  if C^.Text <> nil then
  begin
    kernel_bwt_inverse(C^.Bwt, C^.T, C^.Primary, C^.Samples, C^.NSamples,
                       SAMPLE_RATE, C^.Text);
    C^.Ok := tvct_text_decode(C^.Text, C^.T, C^.Dst, C^.N) = 0;
  end
  else
  begin
    kernel_bwt_inverse(C^.Bwt, C^.T, C^.Primary, C^.Samples, C^.NSamples,
                       SAMPLE_RATE, C^.Dst);
    C^.Ok := True;
  end;
end;

{ Single-stream block: entropy and tail in one guard region. }
procedure GuardDecodeAll(Ctx: Pointer); cdecl;
var
  C: ^TGuardDecode;
begin
  C := Ctx;
  C^.R := bsc_coder_decompress_bounded(C^.Pay, C^.PayLen, C^.Bwt, C^.T,
                                       C^.Coder, 0);
  if C^.R <> C^.T then
    Exit;
  GuardTail(Ctx);
end;

constructor TSegThread.Create(ACtx: Pointer);
begin
  FCtx := ACtx;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSegThread.Execute;
begin
  if GuardRun(@GuardEntropyOne, FCtx) <> 0 then
    FCtx^.Ok := False;
end;

{ Decodes the body in Job.Blk into Job.Data (Job.N bytes). Everything that
  indexes a buffer is checked here first: this is where a corrupt stream that
  got past the body CRC ends up. The payload and every output buffer end at a
  guard page, so the stages run inside one: a fault is a failed block.

  A segmented block splits the BWT output into K independently coded streams;
  they are decoded on K threads and the inverse BWT runs on the joined
  result. }
function DecodeBlock(var Job: TBlockJob): Boolean;
var
  Pos, T, Primary, NSamples, i, PayLen, K, Total, Off, Len, SegOff: Int32;
  V: QWord;
  Ctx: TGuardDecode;
  Seg: array[0..MAX_SEGMENTS - 1] of TSegDecode;
  Th: array[0..MAX_SEGMENTS - 2] of TSegThread;
  SegLen: array[0..MAX_SEGMENTS - 1] of Int32;
  Pay: PByte;
  Samples: PInt32;
  BwtBuf, TextBuf, Dst: PByte;
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
  Dst := nil;
  K := 1;

  if NSamples > 0 then
  begin
    if not NeedGuard(Pointer(Job.SampleScratch), Job.SampleCap,
                     NSamples * SizeOf(Int32)) then
      Exit;
    Samples := Job.SampleScratch;
    { The rows are not 4-byte aligned inside the body. }
    Move(Job.Blk[Pos], Samples^, NSamples * 4);
    Inc(Pos, NSamples * 4);
    for i := 0 to NSamples - 1 do
      if (Samples[k] < 0) or (Samples[k] > T) then
        Exit;
  end;

  { Segmented blocks carry the stream count and their lengths before the
    payload. Every length is checked against what is left of the body. }
  if (Job.Method and METHOD_FLAG_SEGMENTED) <> 0 then
  begin
    if not GetVarint(Job.Blk, Job.BlkLen, Pos, 5, V) or (V < 2) or
       (V > MAX_SEGMENTS) then
      Exit;
    K := Int32(V);
    Total := 0;
    for i := 0 to K - 1 do
    begin
      if not GetVarint(Job.Blk, Job.BlkLen, Pos, 5, V) or (V < 1) or
         (V > QWord(Job.BlkLen)) then
        Exit;
      SegLen[i] := Int32(V);
      Inc(Total, SegLen[i]);
      if (Total < 0) or (Total > Job.BlkLen - Pos) then
        Exit;
    end;
    if Total > Job.BlkLen - Pos then
      Exit;
  end;

  { The payload is copied so that reads past its end fault too. }
  PayLen := Job.BlkLen - Pos;
  if not NeedGuard(Pointer(Job.Pay), Job.PayCap, PayLen) then
    Exit;
  Pay := Job.Pay;
  Move(Job.Blk[Pos], Pay^, PayLen);
  if not NeedGuard(Pointer(Job.BwtScratch), Job.BwtCap, T + 1) then
    Exit;
  BwtBuf := Job.BwtScratch;
  if not NeedGuard(Pointer(Job.DstScratch), Job.DstCap, Job.N) then
    Exit;
  Dst := Job.DstScratch;
  if IsText then
  begin
    if not NeedGuard(Pointer(Job.TextScratch), Job.TextCap, T) then
      Exit;
    TextBuf := Job.TextScratch;
  end;

  Ctx.Pay := Pay;
  Ctx.PayLen := PayLen;
  Ctx.Bwt := BwtBuf;
  Ctx.T := T;
  Ctx.Primary := Primary;
  Ctx.Samples := Samples;
  Ctx.NSamples := NSamples;
  Ctx.Text := TextBuf;
  Ctx.Dst := Dst;
  Ctx.N := Job.N;
  Ctx.Coder := Job.Method and 3;
  Ctx.R := -1;
  Ctx.Ok := False;

  if K = 1 then
  begin
    if GuardRun(@GuardDecodeAll, @Ctx) <> 0 then
      Exit;                                { the stream stepped on a guard }
    if not Ctx.Ok then
      Exit;
  end
  else
  begin
    SegOff := 0;
    for i := 0 to K - 1 do
    begin
      Off := Int32(Int64(T) * i div K);
      Len := Int32(Int64(T) * (i + 1) div K) - Off;
      Seg[i].Pay := Pay + SegOff;
      Seg[i].PayLen := SegLen[i];
      Seg[i].Dst := BwtBuf + Off;
      Seg[i].DstLen := Len;
      Seg[i].Coder := Job.Method and 3;
      Seg[i].Ok := False;
      Inc(SegOff, SegLen[i]);
    end;
    if (Job.Threads > 1) and (K <= Job.Threads) then
    begin
      for i := 0 to K - 2 do
        Th[i] := TSegThread.Create(@Seg[i]);
      if GuardRun(@GuardEntropyOne, @Seg[K - 1]) <> 0 then
        Seg[K - 1].Ok := False;
      for i := 0 to K - 2 do
      begin
        Th[i].WaitFor;
        Th[i].Free;
      end;
    end
    else
      for i := 0 to K - 1 do
        if GuardRun(@GuardEntropyOne, @Seg[i]) <> 0 then
          Seg[i].Ok := False;
    for i := 0 to K - 1 do
      if not Seg[i].Ok then
        Exit;
    if GuardRun(@GuardTail, @Ctx) <> 0 then
      Exit;
    if not Ctx.Ok then
      Exit;
  end;

  Move(Dst^, Job.Data^, Job.N);
  Result := True;
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
  if Opts.Segments > 1 then
    WriteStreamHeader(Dst, Opts.BlockLog, Total, Known, Opts.Digest,
                      CODEC_VERSION_SEGMENTED)
  else
    WriteStreamHeader(Dst, Opts.BlockLog, Total, Known, Opts.Digest,
                      CODEC_VERSION);
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
      FreeScratch(Jobs[i]);
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
  if (Job.Method and not (3 or METHOD_FLAG_SAMPLES or METHOD_FLAG_TEXT or
                          METHOD_FLAG_SEGMENTED)) <> 0 then
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
  Version: Int32;
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
  if not ReadStreamHeader(Src, BlockLog, Total, Version, Known, HasDigest) then
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
      { A block may use as many threads as there are spare ones: if the batch
        fills the pool, the segments decode one after another and the entropy
        stage still gets its bytes. }
      for i := 0 to Count - 1 do
      begin
        Jobs[i].Threads := Threads div Count;
        if Jobs[i].Threads < 1 then
          Jobs[i].Threads := 1;
      end;
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
      FreeScratch(Jobs[i]);
      FreeMem(Jobs[i].Data);
      FreeMem(Jobs[i].Blk);
    end;
  end;
end;

function StreamDataSize(Src: TStream): Int64;
var
  BlockLog, Method, Version: Int32;
  Total: Int64;
  Known, HasDigest: Boolean;
  Orig, Body: QWord;
begin
  Result := -1;
  if not ReadStreamHeader(Src, BlockLog, Total, Version, Known, HasDigest) then
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
