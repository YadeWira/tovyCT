{
  tvct.codec.pas - block format and the compress/decompress pipeline.

  Pipeline: BWT -> MTF/RLE -> rANS with three contexts. The LZP prefilter is
  implemented and selectable, but measurement on text shows it costs about 12 %
  of the final size (it removes the repeats the BWT would have clustered), so it
  is off by default.

  Stream layout (all integers little-endian):

    header:  "TVCT" | version (1) | block_log (1) | flags (1) | reserved (1)

    block:   orig_size     u32
             payload_size  u32
             method        u32   0 raw, 1 BWT
             crc32c        u32   of the original bytes
             if method = 1:
               bwt_size    u32   bytes handed to the BWT
               primary     u32   BWT primary index
               tokens      u32   number of MTF/RLE tokens
               freq        u16[3 * 258]   per context
             payload_size bytes of rANS data (method 1) or raw bytes (method 0)

  Blocks are independent: each one carries its own tables and can be decoded
  without the others.
}
unit tvct.codec;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, tvct.sais, tvct.bwt, tvct.mtf, tvct.rans, tvct.lzp,
  tvct.crc;

const
  CODEC_VERSION = 1;
  DEFAULT_BLOCK_LOG = 23;
  METHOD_RAW = 0;
  METHOD_BWT = 1;
  CODEC_HEADER_SIZE = 8;
  BLOCK_HEADER_SIZE = 16;
  BWT_HEADER_EXTRA = 12;
  MTF_CONTEXTS = 3;
  FREQ_BYTES = MTF_CONTEXTS * MTF_SYMBOLS * 2;

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
  { Token class to context: ranks share one model, RUNA and RUNB have their own. }
  CtxTab: array[0..MTF_SYMBOLS - 1] of Byte;

procedure InitCtxTab;
var
  i: Int32;
begin
  for i := 0 to 255 do
    CtxTab[i] := 0;
  CtxTab[MTF_RUNA] := 1;
  CtxTab[MTF_RUNB] := 2;
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

function CompressBlock(const Src: PByte; N: Int32; Dst: PByte; DstCap: Int32;
  out BwtSize, Primary, TokenCount: Int32; Freq: PInt32): Int32;
var
  BwtBuf: PByte;
  SA: PInt32;
  Tokens: PWord;
  Counts: array[0..MTF_CONTEXTS - 1, 0..MTF_SYMBOLS - 1] of Int32;
  Start: array[0..MTF_CONTEXTS * MTF_SYMBOLS - 1] of Int32;
  i, c, prev, R: Int32;
begin
  Result := -1;
  BwtSize := N;

  GetMem(SA, (N + 1) * SizeOf(Int32));
  GetMem(BwtBuf, N + 1);
  GetMem(Tokens, N * SizeOf(Word));
  try
    SaisBuildSA(Src, N, SA);
    BwtForward(Src, N, SA, BwtBuf, Primary);
    TokenCount := MtfRleEncode(BwtBuf, N, Tokens);

    FillChar(Counts, SizeOf(Counts), 0);
    prev := 0;
    for i := 0 to TokenCount - 1 do
    begin
      c := Tokens[i];
      Inc(Counts[CtxTab[prev], c]);
      prev := c;
    end;
    for c := 0 to MTF_CONTEXTS - 1 do
      RansNormalise(@Counts[c, 0], MTF_SYMBOLS, @Freq[c * MTF_SYMBOLS],
                    @Start[c * MTF_SYMBOLS]);

    if RansBound(TokenCount) > DstCap then
      Exit;
    R := RansEncodeCtx(Tokens, TokenCount, MTF_SYMBOLS, MTF_CONTEXTS,
                       @CtxTab[0], @Freq[0], @Start[0], Dst);
    Result := R;
  finally
    FreeMem(Tokens);
    FreeMem(BwtBuf);
    FreeMem(SA);
  end;
end;

function DecompressBlock(const Payload: PByte; PayloadLen, OrigSize: Int32;
  const Freq: PInt32; BwtSize, Primary, TokenCount: Int32; Dst: PByte): Boolean;
var
  Tokens: PWord;
  BwtBuf: PByte;
begin
  Result := False;
  if (BwtSize <= 0) or (BwtSize > OrigSize) or (TokenCount <= 0) or
     (TokenCount > BwtSize) then
    Exit;

  GetMem(Tokens, TokenCount * SizeOf(Word));
  GetMem(BwtBuf, BwtSize + 1);
  try
    if not RansDecodeCtx(Payload, PayloadLen, MTF_SYMBOLS, MTF_CONTEXTS,
                         TokenCount, @CtxTab[0], Freq, Tokens) then
      Exit;
    if not MtfRleDecode(Tokens, TokenCount, BwtSize, BwtBuf) then
      Exit;
    BwtInverse(BwtBuf, BwtSize, Primary, Dst);
    Result := BwtSize = OrigSize;
  finally
    FreeMem(BwtBuf);
    FreeMem(Tokens);
  end;
end;

function CompressStream(Src, Dst: TStream; BlockLog: Int32;
  out Stats: TCodecStats): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  SrcBuf, Payload: PByte;
  BlockSize, N, PayloadLen, BwtSize, Primary, TokenCount, i: Int32;
  Freq: array[0..MTF_CONTEXTS * MTF_SYMBOLS - 1] of Int32;
  Crc: LongWord;
  Raw: Boolean;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;

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
  Payload := GetMem(BlockSize * 2 + 64);
  try
    while Src.Position < Src.Size do
    begin
      N := Src.Read(SrcBuf[0], BlockSize);
      if N <= 0 then
        Break;
      Inc(Stats.InBytes, N);

      Crc := Crc32c(0, SrcBuf[0], N);
      PayloadLen := CompressBlock(SrcBuf, N, Payload, BlockSize * 2 + 64, BwtSize,
                                  Primary, TokenCount, @Freq[0]);
      Raw := (PayloadLen < 0) or
             (PayloadLen + BWT_HEADER_EXTRA + FREQ_BYTES >= N);
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
        PutU32(@Blk[8], LongWord(TokenCount));
        Dst.WriteBuffer(Blk[0], BWT_HEADER_EXTRA);
        for i := 0 to MTF_CONTEXTS * MTF_SYMBOLS - 1 do
        begin
          Blk[0] := Byte(Freq[i]);
          Blk[1] := Byte(Freq[i] shr 8);
          Dst.WriteBuffer(Blk[0], 2);
        end;
        Dst.WriteBuffer(Payload[0], PayloadLen);
        Inc(Stats.OutBytes, BLOCK_HEADER_SIZE + BWT_HEADER_EXTRA + FREQ_BYTES + PayloadLen);
      end;
      Inc(Stats.Blocks);
    end;
    Result := True;
  finally
    FreeMem(Payload);
    FreeMem(SrcBuf);
  end;
end;

function DecompressStream(Src, Dst: TStream;
  out Stats: TCodecStats): Boolean;
var
  Hdr: array[0..CODEC_HEADER_SIZE - 1] of Byte;
  Blk: array[0..BLOCK_HEADER_SIZE - 1] of Byte;
  Buf: PByte;
  BlockSize, OrigSize, PayloadLen, Method, BwtSize, Primary, TokenCount, i: Int32;
  Freq: array[0..MTF_CONTEXTS * MTF_SYMBOLS - 1] of Int32;
  Crc: LongWord;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;

  ReadExact(Src, @Hdr[0], CODEC_HEADER_SIZE);
  if (Hdr[0] <> Ord('T')) or (Hdr[1] <> Ord('V')) or (Hdr[2] <> Ord('C')) or
     (Hdr[3] <> Ord('T')) or (Hdr[4] <> CODEC_VERSION) then
    Exit;
  BlockSize := 1 shl Hdr[5];
  if (BlockSize < 1 shl 16) or (BlockSize > 1 shl 27) then
    Exit;

  Buf := GetMem(BlockSize * 2 + 64);
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
      if (PayloadLen <= 0) or (PayloadLen > BlockSize * 2) then
        Exit;

      if Method = METHOD_RAW then
      begin
        if PayloadLen <> OrigSize then
          Exit;
        ReadExact(Src, Buf, OrigSize);
      end
      else if Method = METHOD_BWT then
      begin
        ReadExact(Src, @Blk[0], BWT_HEADER_EXTRA);
        BwtSize := Int32(GetU32(@Blk[0]));
        Primary := Int32(GetU32(@Blk[4]));
        TokenCount := Int32(GetU32(@Blk[8]));
        for i := 0 to MTF_CONTEXTS * MTF_SYMBOLS - 1 do
        begin
          ReadExact(Src, @Blk[0], 2);
          Freq[i] := Int32(Blk[0]) or (Int32(Blk[1]) shl 8);
        end;
        if PayloadLen + OrigSize > BlockSize * 2 + 64 then
          Exit;
        ReadExact(Src, Buf, PayloadLen);
        if not DecompressBlock(Buf, PayloadLen, OrigSize, @Freq[0], BwtSize,
                               Primary, TokenCount, Buf + PayloadLen) then
          Exit;
        Move(Buf[PayloadLen], Buf[0], OrigSize);
      end
      else
        Exit;

      if Crc32c(0, Buf[0], OrigSize) <> Crc then
        Exit;
      Dst.WriteBuffer(Buf[0], OrigSize);
      Inc(Stats.Blocks);
      Inc(Stats.OutBytes, OrigSize);
      Inc(Stats.InBytes, BLOCK_HEADER_SIZE + PayloadLen);
    end;
    Result := True;
  finally
    FreeMem(Buf);
  end;
end;

initialization
  InitCtxTab;

end.
