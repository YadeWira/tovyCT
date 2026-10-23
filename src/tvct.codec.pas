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
  CODEC_VERSION = 1;
  DEFAULT_BLOCK_LOG = 23;
  METHOD_RAW = 0;
  METHOD_BWT = 1;
  CODEC_HEADER_SIZE = 8;
  BLOCK_HEADER_SIZE = 16;
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

implementation

var
  BscReady: Boolean = False;

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
    SaisBuildSA(Src, N, SA);
    BwtForward(Src, N, SA, BwtBuf, Primary);
    BuildSamples(SA, N, Samples, NSamples);

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
  R: Int32;
begin
  Result := False;
  if (BwtSize <= 0) or (BwtSize > OrigSize) then
    Exit;
  if NSamples <> (BwtSize + SAMPLE_RATE - 1) div SAMPLE_RATE then
    Exit;

  GetMem(BwtBuf, BwtSize + 1);
  try
    R := bsc_coder_decompress(Payload, BwtBuf, BSC_CODER_STATIC, 0);
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

  Hdr[0] := Ord('T'); Hdr[1] := Ord('V'); Hdr[2] := Ord('C'); Hdr[3] := Ord('T');
  Hdr[4] := CODEC_VERSION;
  Hdr[5] := Byte(BlockLog);
  Hdr[6] := 0;
  Hdr[7] := 0;
  Dst.WriteBuffer(Hdr[0], CODEC_HEADER_SIZE);
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
    i, MaxSamples: Int32;
  Crc: LongWord;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  EnsureBsc;

  ReadExact(Src, @Hdr[0], CODEC_HEADER_SIZE);
  if (Hdr[0] <> Ord('T')) or (Hdr[1] <> Ord('V')) or (Hdr[2] <> Ord('C')) or
     (Hdr[3] <> Ord('T')) or (Hdr[4] <> CODEC_VERSION) then
    Exit;
  BlockSize := 1 shl Hdr[5];
  if (BlockSize < 1 shl 16) or (BlockSize > 1 shl 27) then
    Exit;

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
      if (OrigSize <= 0) or (OrigSize > BlockSize) then
        Exit;
      if (PayloadLen <= 0) or (PayloadLen > BlockSize + 4096) then
        Exit;

      if Method = METHOD_RAW then
      begin
        if PayloadLen <> OrigSize then
          Exit;
        ReadExact(Src, OutBuf, OrigSize);
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
    end;
    Result := True;
  finally
    FreeMem(Samples);
    FreeMem(OutBuf);
    FreeMem(Buf);
  end;
end;

end.
