{
  tvct.codec.pas - block format and the compress/decompress pipeline.

  Pipeline: BWT -> QLFC (libbsc coder), per block, with a raw fallback when the
  result would not be smaller.

  The BWT is built with libsais through tvct.sais. The entropy stage is libbsc's
  quantized local frequency coder: it does its own RLE, MTF and context-conditioned
  arithmetic coding over the BWT output, and measured 15 % smaller than this
  project's own static MTF + rANS at the same speed.

  Stream layout (all integers little-endian):

    header:  "TVCT" | version (1) | block_log (1) | flags (1) | reserved (1)

    block:   orig_size     u32
             payload_size  u32
             method        u32   0 raw, 1 BWT + QLFC
             crc32c        u32   of the original bytes
             if method = 1:
               bwt_size    u32
               primary     u32
               reserved    u32
               samples     u32   number of LF-chain sample rows
               sample rows i32[samples]
             payload_size bytes of QLFC data (method 1) or raw bytes (method 0)

  The sample rows are the LF-chain row of every chunk boundary, taken from the
  inverse suffix array. They cost about 0.1 % of the block and let the decoder
  walk several independent chains instead of one serial one.
}
unit tvct.codec;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, tvct.sais, tvct.bwt, tvct.kernels, tvct.bsc, tvct.crc;

const
  CODEC_VERSION = 3;
  DEFAULT_BLOCK_LOG = 23;
  METHOD_RAW = 0;
  METHOD_BWT = 1;
  CODEC_HEADER_SIZE = 16;   { magic 4, version, block log, flags, reserved, total u64 }
  BLOCK_HEADER_SIZE = 20;   { orig, payload, method, crc, payload crc }
  BWT_HEADER_EXTRA = 16;
  SAMPLE_RATE = 4096;

type
  TCodecStats = record
    InBytes: Int64;
    OutBytes: Int64;
    Blocks: Integer;
    RawBlocks: Integer;
  end;

function CompressStream(Src, Dst: TStream; BlockLog: Int32;
  out Stats: TCodecStats): Boolean;
function DecompressStream(Src, Dst: TStream;
  out Stats: TCodecStats): Boolean;

{ Same, with the blocks of one chunk compressed or decompressed in parallel.
  Blocks are independent, so the output is byte-identical to the sequential
  path; Threads <= 1 uses it. }
function CompressStreamMT(Src, Dst: TStream; BlockLog, Threads: Int32;
  out Stats: TCodecStats): Boolean;
function DecompressStreamMT(Src, Dst: TStream; Threads: Int32;
  out Stats: TCodecStats): Boolean;

{ Total uncompressed size of a stream, read from the block headers without
  decoding anything. Returns -1 if the stream header is not valid. }
function StreamDataSize(Src: TStream): Int64;

implementation

type
  TBlockJob = record
    Src, Payload, OutBuf: PByte;
    Samples: PInt32;
    N, PayloadLen, BwtSize, Primary, NSamples: Int32;
    Crc: LongWord;
    Raw, Ok: Boolean;
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

function CompressBlock(const Src: PByte; N: Int32; Dst: PByte; DstCap: Int32;
  Samples: PInt32; out BwtSize, Primary, NSamples: Int32): Int32; forward;
function DecompressBlock(const Payload: PByte; PayloadLen, OrigSize: Int32;
  BwtSize, Primary, NSamples: Int32; const Samples: PInt32;
  Dst: PByte): Boolean; forward;

var
  BscReady: Boolean = False;

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
    begin
      FJob^.Crc := Crc32c(0, FJob^.Src[0], FJob^.N);
      FJob^.PayloadLen := CompressBlock(FJob^.Src, FJob^.N, FJob^.Payload,
        FJob^.N + 4096, FJob^.Samples, FJob^.BwtSize, FJob^.Primary,
        FJob^.NSamples);
      FJob^.Raw := (FJob^.PayloadLen < 0) or
        (FJob^.PayloadLen + BWT_HEADER_EXTRA + FJob^.NSamples * 4 + 16 >= FJob^.N);
      FJob^.Ok := True;
    end
    else
      FJob^.Ok := DecompressBlock(FJob^.Payload, FJob^.PayloadLen, FJob^.N,
        FJob^.BwtSize, FJob^.Primary, FJob^.NSamples, FJob^.Samples,
        FJob^.OutBuf);
  except
    FJob^.Ok := False;
  end;
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

procedure PutU64(P: PByte; V: Int64); inline;
var
  U: QWord;
  i: Int32;
begin
  U := QWord(V);
  for i := 0 to 7 do
    P[i] := Byte(U shr (8 * i));
end;

function GetU64(P: PByte): Int64; inline;
var
  U: QWord;
  i: Int32;
begin
  U := 0;
  for i := 7 downto 0 do
    U := (U shl 8) or QWord(P[i]);
  Result := Int64(U);
end;

procedure ReadExact(S: TStream; P: PByte; N: Int32); forward;

{ The stream header: magic, version, block log, flags, reserved and the total
  uncompressed size (0 when the source size was unknown). }
procedure WriteHeader(Dst: TStream; BlockLog: Int32; Total: Int64; Known: Boolean);
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
begin
  Hdr[0] := Ord('T'); Hdr[1] := Ord('V'); Hdr[2] := Ord('C'); Hdr[3] := Ord('T');
  Hdr[4] := CODEC_VERSION;
  Hdr[5] := Byte(BlockLog);
  Hdr[6] := Ord(Known);
  Hdr[7] := 0;
  PutU64(@Hdr[8], Total);
  Dst.WriteBuffer(Hdr[0], CODEC_HEADER_SIZE);
end;

function ReadHeader(Src: TStream; out BlockLog: Int32; out Total: Int64;
  out Known: Boolean): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
begin
  Result := False;
  if Src.Size - Src.Position < CODEC_HEADER_SIZE then
    Exit;
  ReadExact(Src, @Hdr[0], CODEC_HEADER_SIZE);
  if (Hdr[0] <> Ord('T')) or (Hdr[1] <> Ord('V')) or (Hdr[2] <> Ord('C')) or
     (Hdr[3] <> Ord('T')) or (Hdr[4] <> CODEC_VERSION) then
    Exit;
  BlockLog := Hdr[5];
  Known := (Hdr[6] and 1) <> 0;
  Total := GetU64(@Hdr[8]);
  if Known and (Total < 0) then
    Exit;
  Result := (BlockLog >= 16) and (BlockLog <= 27);
end;

function GetU32(P: PByte): LongWord; inline;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or
            (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

procedure ReadExact(S: TStream; P: PByte; N: Int32);
begin
  if N <= 0 then
    Exit;
  if S.Read(P[0], N) <> N then
    raise Exception.Create('unexpected end of stream');
end;

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

function CompressBlock(const Src: PByte; N: Int32; Dst: PByte; DstCap: Int32;
  Samples: PInt32; out BwtSize, Primary, NSamples: Int32): Int32;
var
  BwtBuf: PByte;
  SA: PInt32;
  R: Int32;
begin
  Result := -1;
  BwtSize := N;
  NSamples := 0;

  GetMem(SA, (N + 1) * SizeOf(Int32));
  GetMem(BwtBuf, N + 1);
  try
{$IFDEF TVCT_LIBSAIS}
    { One pass gives the BWT, the primary index and the sample rows. }
    if libsais_bwt_aux(Src, BwtBuf, SA, N, 0, nil, SAMPLE_RATE, Samples) < 0 then
      Exit;
    Primary := Samples[0];
    NSamples := (N + SAMPLE_RATE - 1) div SAMPLE_RATE;
    Move(Samples[1], Samples[0], (NSamples - 1) * SizeOf(Int32));
    Samples[NSamples - 1] := 0;
{$ELSE}
    SaisBuildSA(Src, N, SA);
    BwtForward(Src, N, SA, BwtBuf, Primary);
    BuildSamples(SA, N, Samples, NSamples);
{$ENDIF}

    if DstCap < N then
      Exit;
    R := bsc_coder_compress(BwtBuf, Dst, N, BSC_CODER_STATIC, 0);
    if R <= 0 then
      Exit;
    Result := R;
  finally
    FreeMem(BwtBuf);
    FreeMem(SA);
  end;
end;

function DecompressBlock(const Payload: PByte; PayloadLen, OrigSize: Int32;
  BwtSize, Primary, NSamples: Int32; const Samples: PInt32;
  Dst: PByte): Boolean;
var
  BwtBuf: PByte;
  R, k: Int32;
begin
  Result := False;
  if (BwtSize <= 0) or (BwtSize > OrigSize) then
    Exit;
  if NSamples <> (BwtSize + SAMPLE_RATE - 1) div SAMPLE_RATE then
    Exit;
  { Everything that indexes the BWT or the LF table must be in range before any
    buffer is touched: this is the only place a corrupt stream can get through. }
  if (Primary < 0) or (Primary > BwtSize) then
    Exit;
  for k := 0 to NSamples - 1 do
    if (Samples[k] < 0) or (Samples[k] > BwtSize) then
      Exit;

  GetMem(BwtBuf, BwtSize + 1);
  try
    if GetEnvironmentVariable('TVCT_DEBUG') <> '' then WriteLn(StdErr, 'dbg: bsc decode start');
    bsc_qlfc_set_output_limit(BwtSize);
    bsc_qlfc_set_input_end(Payload + PayloadLen);
    R := bsc_coder_decompress(Payload, BwtBuf, BSC_CODER_STATIC, 0);
    bsc_qlfc_set_output_limit(0);
    bsc_qlfc_set_input_end(nil);
    if GetEnvironmentVariable('TVCT_DEBUG') <> '' then WriteLn(StdErr, 'dbg: bsc decode done ', R);
    if R <> BwtSize then
      Exit;
    kernel_bwt_inverse(BwtBuf, BwtSize, Primary, Samples, NSamples, SAMPLE_RATE,
                       Dst);
    Result := BwtSize = OrigSize;
  finally
    FreeMem(BwtBuf);
  end;
end;

function CompressStream(Src, Dst: TStream; BlockLog: Int32;
  out Stats: TCodecStats): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  SrcBuf, Payload: PByte;
  Samples: PInt32;
  BlockSize, N, PayloadLen, BwtSize, Primary, NSamples, i: Int32;
  Crc: LongWord;
  Raw: Boolean;
  Total: Int64;
  Known: Boolean;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  EnsureBsc;

  if (BlockLog < 16) or (BlockLog > 27) then
    Exit;
  BlockSize := 1 shl BlockLog;

  Known := False;
  Total := 0;
  try
    Total := Int64(Src.Size) - Int64(Src.Position);
    Known := Total >= 0;
  except
    Known := False;
  end;
  WriteHeader(Dst, BlockLog, Total, Known);
  Stats.OutBytes := CODEC_HEADER_SIZE;

  SrcBuf := GetMem(BlockSize);
  Payload := GetMem(BlockSize + 4096);
  Samples := GetMem((BlockSize div SAMPLE_RATE + 2) * SizeOf(Int32));
  try
    while Src.Position < Src.Size do
    begin
      N := Src.Read(SrcBuf[0], BlockSize);
      if N <= 0 then
        Break;
      Inc(Stats.InBytes, N);

      Crc := Crc32c(0, SrcBuf[0], N);
      PayloadLen := CompressBlock(SrcBuf, N, Payload, BlockSize + 4096,
                                  Samples, BwtSize, Primary, NSamples);
      Raw := (PayloadLen < 0) or
             (PayloadLen + BWT_HEADER_EXTRA + NSamples * 4 + 16 >= N);
      if Raw then
      begin
        PutU32(@Blk[0], LongWord(N));
        PutU32(@Blk[4], LongWord(N));
        PutU32(@Blk[8], LongWord(METHOD_RAW));
        PutU32(@Blk[12], Crc);
        PutU32(@Blk[16], Crc32c(0, SrcBuf[0], N));
        Dst.WriteBuffer(Blk[0], BLOCK_HEADER_SIZE);
        Dst.WriteBuffer(SrcBuf[0], N);
        Inc(Stats.OutBytes, BLOCK_HEADER_SIZE + N);
        Inc(Stats.RawBlocks);
      end
      else
      begin
        PutU32(@Blk[0], LongWord(N));
        PutU32(@Blk[4], LongWord(PayloadLen));
        PutU32(@Blk[8], LongWord(METHOD_BWT));
        PutU32(@Blk[12], Crc);
        PutU32(@Blk[16], Crc32c(0, Payload[0], PayloadLen));
        Dst.WriteBuffer(Blk[0], BLOCK_HEADER_SIZE);
        PutU32(@Blk[0], LongWord(BwtSize));
        PutU32(@Blk[4], LongWord(Primary));
        PutU32(@Blk[8], 0);
        PutU32(@Blk[12], LongWord(NSamples));
        Dst.WriteBuffer(Blk[0], BWT_HEADER_EXTRA);
        Dst.WriteBuffer(Samples[0], NSamples * SizeOf(Int32));
        Dst.WriteBuffer(Payload[0], PayloadLen);
        Inc(Stats.OutBytes, BLOCK_HEADER_SIZE + BWT_HEADER_EXTRA +
            NSamples * 4 + PayloadLen);
      end;
      Inc(Stats.Blocks);
    end;
    Result := True;
  finally
    FreeMem(Samples);
    FreeMem(Payload);
    FreeMem(SrcBuf);
  end;
end;

function DecompressStream(Src, Dst: TStream;
  out Stats: TCodecStats): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  Buf, OutBuf, Samples: PByte;
  BlockSize, OrigSize, PayloadLen, Method, BwtSize, Primary, NSamples,
    i, MaxSamples, BlockLog: Int32;
  Crc, PayloadCrc: LongWord;
  Total, Decoded: Int64;
  Known: Boolean;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  EnsureBsc;

  if not ReadHeader(Src, BlockLog, Total, Known) then
    Exit;
  BlockSize := 1 shl BlockLog;
  Decoded := 0;

  Buf := GetMem(BlockSize + 4096);
  OutBuf := GetMem(BlockSize);
  MaxSamples := BlockSize div SAMPLE_RATE + 2;
  Samples := GetMem(MaxSamples * SizeOf(Int32));
  try
    while Src.Position < Src.Size do
    begin
      ReadExact(Src, @Blk[0], BLOCK_HEADER_SIZE);
      OrigSize := Int32(GetU32(@Blk[0]));
      PayloadLen := Int32(GetU32(@Blk[4]));
      Method := Int32(GetU32(@Blk[8]));
      Crc := GetU32(@Blk[12]);
      PayloadCrc := GetU32(@Blk[16]);
      if (OrigSize <= 0) or (OrigSize > BlockSize) then
        Exit;
      if (PayloadLen <= 0) or (PayloadLen > BlockSize + 4096) then
        Exit;

      if Method = METHOD_RAW then
      begin
        if PayloadLen <> OrigSize then
          Exit;
        ReadExact(Src, OutBuf, OrigSize);
        if Crc32c(0, OutBuf[0], OrigSize) <> PayloadCrc then
          Exit;
      end
      else if Method = METHOD_BWT then
      begin
        ReadExact(Src, @Blk[0], BWT_HEADER_EXTRA);
        BwtSize := Int32(GetU32(@Blk[0]));
        Primary := Int32(GetU32(@Blk[4]));
        NSamples := Int32(GetU32(@Blk[12]));
        if (NSamples <= 0) or (NSamples > MaxSamples) then
          Exit;
        ReadExact(Src, Samples, NSamples * SizeOf(Int32));
        ReadExact(Src, Buf, PayloadLen);
        if Crc32c(0, Buf[0], PayloadLen) <> PayloadCrc then
          Exit;
        if not DecompressBlock(Buf, PayloadLen, OrigSize, BwtSize, Primary,
                               NSamples, PInt32(Samples), OutBuf) then
          Exit;
      end
      else
        Exit;

      if Crc32c(0, OutBuf[0], OrigSize) <> Crc then
        Exit;
      Dst.WriteBuffer(OutBuf[0], OrigSize);
      Inc(Stats.Blocks);
      Inc(Stats.OutBytes, OrigSize);
      Inc(Stats.InBytes, BLOCK_HEADER_SIZE + PayloadLen);
      Inc(Decoded, OrigSize);
      if Known and (Decoded > Total) then
        Exit;
    end;
    if Known and (Decoded <> Total) then
      Exit;
    Result := True;
  finally
    FreeMem(Samples);
    FreeMem(OutBuf);
    FreeMem(Buf);
  end;
end;


function CompressStreamMT(Src, Dst: TStream; BlockLog, Threads: Int32;
  out Stats: TCodecStats): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  Jobs: array of TBlockJob;
  Workers: array of TBlockWorker;
  BlockSize, count, i, MaxSamples: Int32;
  Total: Int64;
  Known: Boolean;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  if Threads <= 1 then
    Exit(CompressStream(Src, Dst, BlockLog, Stats));
  if (BlockLog < 16) or (BlockLog > 27) then
    Exit;
  EnsureBsc;
  BlockSize := 1 shl BlockLog;
  MaxSamples := BlockSize div SAMPLE_RATE + 2;

  Known := False;
  Total := 0;
  try
    Total := Int64(Src.Size) - Int64(Src.Position);
    Known := Total >= 0;
  except
    Known := False;
  end;
  WriteHeader(Dst, BlockLog, Total, Known);
  Stats.OutBytes := CODEC_HEADER_SIZE;

  SetLength(Jobs, Threads);
  SetLength(Workers, Threads);
  for i := 0 to Threads - 1 do
  begin
    Jobs[i].Src := GetMem(BlockSize);
    Jobs[i].Payload := GetMem(BlockSize + 4096);
    Jobs[i].Samples := GetMem(MaxSamples * SizeOf(Int32));
    Jobs[i].Ok := False;
  end;
  try
    repeat
      count := 0;
      while (count < Threads) and (Src.Position < Src.Size) do
      begin
        Jobs[count].N := Src.Read(Jobs[count].Src[0], BlockSize);
        if Jobs[count].N <= 0 then
          Break;
        Inc(count);
      end;
      if count = 0 then
        Break;

      for i := 0 to count - 1 do
        Workers[i] := TBlockWorker.Create(@Jobs[i], True);
      for i := 0 to count - 1 do
      begin
        Workers[i].WaitFor;
        Workers[i].Free;
        Workers[i] := nil;
      end;

      for i := 0 to count - 1 do
      begin
        if not Jobs[i].Ok then
          Exit;
        if Jobs[i].Raw then
        begin
          PutU32(@Blk[0], LongWord(Jobs[i].N));
          PutU32(@Blk[4], LongWord(Jobs[i].N));
          PutU32(@Blk[8], LongWord(METHOD_RAW));
          PutU32(@Blk[12], Jobs[i].Crc);
          PutU32(@Blk[16], Crc32c(0, Jobs[i].Src[0], Jobs[i].N));
          Dst.WriteBuffer(Blk[0], BLOCK_HEADER_SIZE);
          Dst.WriteBuffer(Jobs[i].Src[0], Jobs[i].N);
          Inc(Stats.OutBytes, BLOCK_HEADER_SIZE + Jobs[i].N);
          Inc(Stats.RawBlocks);
        end
        else
        begin
          PutU32(@Blk[0], LongWord(Jobs[i].N));
          PutU32(@Blk[4], LongWord(Jobs[i].PayloadLen));
          PutU32(@Blk[8], LongWord(METHOD_BWT));
          PutU32(@Blk[12], Jobs[i].Crc);
          PutU32(@Blk[16], Crc32c(0, Jobs[i].Payload[0], Jobs[i].PayloadLen));
          Dst.WriteBuffer(Blk[0], BLOCK_HEADER_SIZE);
          PutU32(@Blk[0], LongWord(Jobs[i].BwtSize));
          PutU32(@Blk[4], LongWord(Jobs[i].Primary));
          PutU32(@Blk[8], 0);
          PutU32(@Blk[12], LongWord(Jobs[i].NSamples));
          Dst.WriteBuffer(Blk[0], BWT_HEADER_EXTRA);
          Dst.WriteBuffer(Jobs[i].Samples[0], Jobs[i].NSamples * SizeOf(Int32));
          Dst.WriteBuffer(Jobs[i].Payload[0], Jobs[i].PayloadLen);
          Inc(Stats.OutBytes, BLOCK_HEADER_SIZE + BWT_HEADER_EXTRA +
              Jobs[i].NSamples * 4 + Jobs[i].PayloadLen);
        end;
        Inc(Stats.InBytes, Jobs[i].N);
        Inc(Stats.Blocks);
      end;
    until False;
    Result := True;
  finally
    for i := 0 to Threads - 1 do
    begin
      FreeMem(Jobs[i].Src);
      FreeMem(Jobs[i].Payload);
      FreeMem(Jobs[i].Samples);
    end;
  end;
end;

function DecompressStreamMT(Src, Dst: TStream; Threads: Int32;
  out Stats: TCodecStats): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  Jobs: array of TBlockJob;
  Workers: array of TBlockWorker;
  BlockSize, count, i, Method, MaxSamples, BlockLog: Int32;
  PayloadCrc: LongWord;
  Total, Decoded: Int64;
  Known: Boolean;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  if Threads <= 1 then
    Exit(DecompressStream(Src, Dst, Stats));
  EnsureBsc;

  if not ReadHeader(Src, BlockLog, Total, Known) then
    Exit;
  BlockSize := 1 shl BlockLog;
  Decoded := 0;
  MaxSamples := BlockSize div SAMPLE_RATE + 2;

  SetLength(Jobs, Threads);
  SetLength(Workers, Threads);
  for i := 0 to Threads - 1 do
  begin
    Jobs[i].Payload := GetMem(BlockSize + 4096);
    Jobs[i].OutBuf := GetMem(BlockSize);
    Jobs[i].Samples := GetMem(MaxSamples * SizeOf(Int32));
    Jobs[i].Ok := False;
  end;
  try
    repeat
      count := 0;
      while (count < Threads) and (Src.Position < Src.Size) do
      begin
        ReadExact(Src, @Blk[0], BLOCK_HEADER_SIZE);
        Jobs[count].N := Int32(GetU32(@Blk[0]));
        Jobs[count].PayloadLen := Int32(GetU32(@Blk[4]));
        Method := Int32(GetU32(@Blk[8]));
        Jobs[count].Crc := GetU32(@Blk[12]);
        PayloadCrc := GetU32(@Blk[16]);
        if (Jobs[count].N <= 0) or (Jobs[count].N > BlockSize) then
          Exit;
        if Jobs[count].PayloadLen <= 0 then
          Exit;
        if Method = METHOD_RAW then
        begin
          if Jobs[count].PayloadLen <> Jobs[count].N then
            Exit;
          ReadExact(Src, Jobs[count].OutBuf, Jobs[count].N);
          if Crc32c(0, Jobs[count].OutBuf[0], Jobs[count].N) <> PayloadCrc then
            Exit;
          Jobs[count].Raw := True;
          Jobs[count].Ok := True;
        end
        else if Method = METHOD_BWT then
        begin
          ReadExact(Src, @Blk[0], BWT_HEADER_EXTRA);
          Jobs[count].BwtSize := Int32(GetU32(@Blk[0]));
          Jobs[count].Primary := Int32(GetU32(@Blk[4]));
          Jobs[count].NSamples := Int32(GetU32(@Blk[12]));
          if (Jobs[count].NSamples <= 0) or (Jobs[count].NSamples > MaxSamples) then
            Exit;
          ReadExact(Src, PByte(Jobs[count].Samples), Jobs[count].NSamples * SizeOf(Int32));
          ReadExact(Src, Jobs[count].Payload, Jobs[count].PayloadLen);
          if Crc32c(0, Jobs[count].Payload[0], Jobs[count].PayloadLen) <> PayloadCrc then
            Exit;
          Jobs[count].Raw := False;
        end
        else
          Exit;
        Inc(count);
      end;
      if count = 0 then
        Break;

      for i := 0 to count - 1 do
        if not Jobs[i].Raw then
          Workers[i] := TBlockWorker.Create(@Jobs[i], False);
      for i := 0 to count - 1 do
        if Workers[i] <> nil then
        begin
          Workers[i].WaitFor;
          Workers[i].Free;
          Workers[i] := nil;
        end;

      for i := 0 to count - 1 do
      begin
        if not Jobs[i].Ok then
          Exit;
        if Crc32c(0, Jobs[i].OutBuf[0], Jobs[i].N) <> Jobs[i].Crc then
          Exit;
        Dst.WriteBuffer(Jobs[i].OutBuf[0], Jobs[i].N);
        Inc(Stats.OutBytes, Jobs[i].N);
        Inc(Decoded, Jobs[i].N);
        if Known and (Decoded > Total) then
          Exit;
        if Jobs[i].Raw then
        begin
          Inc(Stats.InBytes, BLOCK_HEADER_SIZE + Jobs[i].N);
          Inc(Stats.RawBlocks);
        end
        else
          Inc(Stats.InBytes, BLOCK_HEADER_SIZE + BWT_HEADER_EXTRA +
              Jobs[i].NSamples * 4 + Jobs[i].PayloadLen);
        Inc(Stats.Blocks);
      end;
    until False;
    if Known and (Decoded <> Total) then
      Exit;
    Result := True;
  finally
    for i := 0 to Threads - 1 do
    begin
      FreeMem(Jobs[i].Payload);
      FreeMem(Jobs[i].OutBuf);
      FreeMem(Jobs[i].Samples);
    end;
  end;
end;

function StreamDataSize(Src: TStream): Int64;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  OrigSize, PayloadLen, Method, NSamples, BlockLog: Int32;
  Total: Int64;
  Known: Boolean;
begin
  Result := -1;
  if Src.Size - Src.Position < CODEC_HEADER_SIZE then
    Exit;
  if not ReadHeader(Src, BlockLog, Total, Known) then
    Exit;
  if Known then
    Exit(Total);
  Result := 0;
  while Src.Position + BLOCK_HEADER_SIZE <= Src.Size do
  begin
    ReadExact(Src, @Blk[0], BLOCK_HEADER_SIZE);
    OrigSize := Int32(GetU32(@Blk[0]));
    PayloadLen := Int32(GetU32(@Blk[4]));
    Method := Int32(GetU32(@Blk[8]));
    if (OrigSize <= 0) or (PayloadLen <= 0) then
      Exit(-1);
    if Method = METHOD_RAW then
    begin
      if PayloadLen <> OrigSize then
        Exit(-1);
      Inc(Result, OrigSize);
      Src.Seek(PayloadLen, soCurrent);
    end
    else if Method = METHOD_BWT then
    begin
      ReadExact(Src, @Blk[0], BWT_HEADER_EXTRA);
      NSamples := Int32(GetU32(@Blk[12]));
      if (NSamples <= 0) or (NSamples > (1 shl 27) div SAMPLE_RATE + 2) then
        Exit(-1);
      Inc(Result, OrigSize);
      Src.Seek(NSamples * SizeOf(Int32) + PayloadLen, soCurrent);
    end
    else
      Exit(-1);
  end;
end;

end.
