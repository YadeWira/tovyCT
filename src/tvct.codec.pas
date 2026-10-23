{
  tvct.codec.pas - block format and the compress/decompress pipeline.

  Pipeline: BWT -> MTF/RLE -> rANS with three contexts. The LZP prefilter is
  implemented and selectable, but measurement on text shows it costs about 12 %
  of the final size with a short minimum match (it removes the repeats the BWT
  would have clustered), so it is off.

  Decoding runs in the C kernels; the encoder is Pascal except for libsais.

  Stream layout (all integers little-endian):

    header:  "TVCT" | version (1) | block_log (1) | flags (1) | reserved (1)

    block:   orig_size     u32
             payload_size  u32
             method        u32   0 raw, 1 BWT
             crc32c        u32   of the original bytes
             if method = 1:
               bwt_size     u32
               primary      u32
               tokens       u32
               samples      u32
               freq         u16[3 * 258]   per context
               sample rows  i32[samples]
             payload_size bytes of rANS data (method 1) or raw bytes (method 0)

  The sample rows are the LF-chain row of every chunk boundary, taken from the
  inverse suffix array. They cost about 0.1 % of the block and let the decoder
  walk several independent chains instead of one serial one.
}
unit tvct.codec;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Classes, SysUtils, tvct.sais, tvct.bwt, tvct.mtf, tvct.rans, tvct.crc,
  tvct.kernels;

const
  CODEC_VERSION = 1;
  DEFAULT_BLOCK_LOG = 23;
  METHOD_RAW = 0;
  METHOD_BWT = 1;
  METHOD_CM = 2;
  CODEC_HEADER_SIZE = 8;
  BLOCK_HEADER_SIZE = 16;
  BWT_HEADER_EXTRA = 16;
  MTF_CONTEXTS = 3;
  FREQ_BYTES = MTF_CONTEXTS * MTF_SYMBOLS * 2;
  SAMPLE_RATE = 4096;

var
  { Selects the context-mixing backend (method 2) instead of MTF + rANS. }
  CodecUseCM: Boolean = False;

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
  CtxTab: array[0..MTF_SYMBOLS - 1] of Byte;
  ProfRans, ProfMtf, ProfBwt, ProfRead, ProfCrc, ProfMove, ProfWrite, ProfTotal: Double;
  ProfEncSA, ProfEncBwt, ProfEncSamp, ProfEncMtf, ProfEncNorm, ProfEncRans: Double;
  ProfOn: Boolean = False;

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

{ Builds the LF-chain sample rows: for chunk j, the row of output position
  min((j+1) * SAMPLE_RATE, N) - 1. The row of position p is 1 + InvSA[p], and
  InvSA[p] is simply the index of p while scanning SA, so this stays sequential:
  random writes into an InvSA array cost six times more than the whole pass. }
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

function DecompressBlock(const Payload: PByte; PayloadLen, OrigSize: Int32;
  const Freq: PInt32; BwtSize, Primary, TokenCount, NSamples: Int32;
  const Samples: PInt32; Dst: PByte; Method: Int32): Boolean; forward;

function CompressBlock(const Src: PByte; N: Int32; Dst: PByte; DstCap: Int32;
  Samples: PInt32; out BwtSize, Primary, TokenCount, NSamples: Int32;
  Freq: PInt32; UseCM: Boolean): Int32;
var
  BwtBuf: PByte;
  SA: PInt32;
  Tokens: PWord;
  Counts: array[0..MTF_CONTEXTS - 1, 0..MTF_SYMBOLS - 1] of Int32;
  Start: array[0..MTF_CONTEXTS * MTF_SYMBOLS - 1] of Int32;
  i, c, prev, R: Int32;
  Tmp: PByte;
  TS: TDateTime;
begin
  Result := -1;
  BwtSize := N;
  NSamples := 0;

  GetMem(SA, (N + 1) * SizeOf(Int32));
  GetMem(BwtBuf, N + 1);
  GetMem(Tokens, N * SizeOf(Word));
  try
    TS := Now;
    SaisBuildSA(Src, N, SA);
    ProfEncSA := ProfEncSA + (Now - TS) * SecsPerDay; TS := Now;
    BwtForward(Src, N, SA, BwtBuf, Primary);
    ProfEncBwt := ProfEncBwt + (Now - TS) * SecsPerDay; TS := Now;
    BuildSamples(SA, N, Samples, NSamples);
    ProfEncSamp := ProfEncSamp + (Now - TS) * SecsPerDay; TS := Now;
    if UseCM then
    begin
      TokenCount := 0;
      if kernel_cm_encode(BwtBuf, N, Dst, DstCap, R) = 0 then
        Exit;
      Result := R;
      Exit;
    end;
    TokenCount := MtfRleEncode(BwtBuf, N, Tokens);
    ProfEncMtf := ProfEncMtf + (Now - TS) * SecsPerDay; TS := Now;

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
    ProfEncNorm := ProfEncNorm + (Now - TS) * SecsPerDay; TS := Now;

    if RansBound(TokenCount) > DstCap then
      Exit;
    R := RansEncodeCtx(Tokens, TokenCount, MTF_SYMBOLS, MTF_CONTEXTS,
                       @CtxTab[0], @Freq[0], @Start[0], Dst);
    ProfEncRans := ProfEncRans + (Now - TS) * SecsPerDay;
    Result := R;
    if (R > 0) and (GetEnvironmentVariable('TVCT_SELFCHECK') <> '') then
    begin
      GetMem(Tmp, N);
      try
        if DecompressBlock(Dst, R, N, @Freq[0], BwtSize, Primary, TokenCount,
                           NSamples, Samples, Tmp,
                           Ord(UseCM) + 1) then
        begin
          i := 0;
          while (i < N) and (Tmp[i] = Src[i]) do Inc(i);
          if i < N then
            WriteLn(StdErr, 'selfcheck: first mismatch at ', i)
          else
            WriteLn(StdErr, 'selfcheck: ok');
        end
        else
          WriteLn(StdErr, 'selfcheck: decode failed');
      finally
        FreeMem(Tmp);
      end;
    end;
  finally
    FreeMem(Tokens);
    FreeMem(BwtBuf);
    FreeMem(SA);
  end;
end;

function DecompressBlock(const Payload: PByte; PayloadLen, OrigSize: Int32;
  const Freq: PInt32; BwtSize, Primary, TokenCount, NSamples: Int32;
  const Samples: PInt32; Dst: PByte; Method: Int32): Boolean;
var
  Tokens: PWord;
  BwtBuf: PByte;
  T0: TDateTime;
begin
  Result := False;
  if (BwtSize <= 0) or (BwtSize > OrigSize) then
    Exit;
  if NSamples <> (BwtSize + SAMPLE_RATE - 1) div SAMPLE_RATE then
    Exit;

  if Method = METHOD_CM then
  begin
    GetMem(BwtBuf, BwtSize + 1);
    try
      if kernel_cm_decode(Payload, PayloadLen, BwtSize, BwtBuf) = 0 then
        Exit;
      kernel_bwt_inverse(BwtBuf, BwtSize, Primary, Samples, NSamples,
                         SAMPLE_RATE, Dst);
      Result := BwtSize = OrigSize;
    finally
      FreeMem(BwtBuf);
    end;
    Exit;
  end;

  if (TokenCount <= 0) or (TokenCount > BwtSize) then
    Exit;

  GetMem(Tokens, TokenCount * SizeOf(Word));
  GetMem(BwtBuf, BwtSize + 1);
  T0 := Now;
  try
    if GetEnvironmentVariable('TVCT_PASDEC') <> '' then
    begin
      if not RansDecodeCtx(Payload, PayloadLen, MTF_SYMBOLS, MTF_CONTEXTS,
                           TokenCount, @CtxTab[0], Freq, Tokens) then
        Exit;
      if not MtfRleDecode(Tokens, TokenCount, BwtSize, BwtBuf) then
        Exit;
      BwtInverse(BwtBuf, BwtSize, Primary, Dst);
      Exit(BwtSize = OrigSize);
    end;
    if kernel_rans_decode(Payload, PayloadLen, MTF_SYMBOLS, MTF_CONTEXTS,
                          TokenCount, @CtxTab[0], Freq, Tokens) = 0 then
      Exit;
    if ProfOn then begin ProfRans := ProfRans + (Now - T0) * SecsPerDay; T0 := Now; end;
    if kernel_mtf_rle_decode(Tokens, TokenCount, BwtSize, BwtBuf) = 0 then
      Exit;
    if ProfOn then begin ProfMtf := ProfMtf + (Now - T0) * SecsPerDay; T0 := Now; end;
    kernel_bwt_inverse(BwtBuf, BwtSize, Primary, Samples, NSamples, SAMPLE_RATE,
                       Dst);
    if ProfOn then ProfBwt := ProfBwt + (Now - T0) * SecsPerDay;
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
  Samples: PInt32;
  BlockSize, N, PayloadLen, BwtSize, Primary, TokenCount, NSamples, i: Int32;
  Freq: array[0..MTF_CONTEXTS * MTF_SYMBOLS - 1] of Int32;
  Crc: LongWord;
  Raw: Boolean;
  R, HH, Method: Int32;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  ProfOn := GetEnvironmentVariable('TVCT_PROFILE') <> '';
  ProfEncSA := 0; ProfEncBwt := 0; ProfEncSamp := 0; ProfEncMtf := 0; ProfEncNorm := 0; ProfEncRans := 0;

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
  Samples := GetMem((BlockSize div SAMPLE_RATE + 2) * SizeOf(Int32));
  try
    while Src.Position < Src.Size do
    begin
      N := Src.Read(SrcBuf[0], BlockSize);
      if N <= 0 then
        Break;
      Inc(Stats.InBytes, N);

      Crc := Crc32c(0, SrcBuf[0], N);
      PayloadLen := CompressBlock(SrcBuf, N, Payload, BlockSize * 2 + 64,
                                  Samples, BwtSize, Primary, TokenCount,
                                  NSamples, @Freq[0], CodecUseCM);
      if CodecUseCM then
        R := BWT_HEADER_EXTRA + NSamples * 4 + 16
      else
        R := BWT_HEADER_EXTRA + FREQ_BYTES + NSamples * 4 + 16;
      Raw := (PayloadLen < 0) or (PayloadLen + R >= N);
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
        if CodecUseCM then
          Method := METHOD_CM
        else
          Method := METHOD_BWT;
        PutU32(@Blk[0], LongWord(N));
        PutU32(@Blk[4], LongWord(PayloadLen));
        PutU32(@Blk[8], LongWord(Method));
        PutU32(@Blk[12], Crc);
        Dst.WriteBuffer(Blk[0], BLOCK_HEADER_SIZE);
        PutU32(@Blk[0], LongWord(BwtSize));
        PutU32(@Blk[4], LongWord(Primary));
        PutU32(@Blk[8], LongWord(TokenCount));
        PutU32(@Blk[12], LongWord(NSamples));
        Dst.WriteBuffer(Blk[0], BWT_HEADER_EXTRA);
        if Method = METHOD_BWT then
          for i := 0 to MTF_CONTEXTS * MTF_SYMBOLS - 1 do
          begin
            Blk[0] := Byte(Freq[i]);
            Blk[1] := Byte(Freq[i] shr 8);
            Dst.WriteBuffer(Blk[0], 2);
          end;
        Dst.WriteBuffer(Samples[0], NSamples * SizeOf(Int32));
        Dst.WriteBuffer(Payload[0], PayloadLen);
        Inc(Stats.OutBytes, BLOCK_HEADER_SIZE + BWT_HEADER_EXTRA + FREQ_BYTES +
            NSamples * 4 + PayloadLen);
      end;
      Inc(Stats.Blocks);
    end;
    if ProfOn then
      WriteLn(StdErr, Format('encode: sa %.2fs bwt %.2fs samples %.2fs mtf %.2fs norm %.2fs rans %.2fs',
        [ProfEncSA, ProfEncBwt, ProfEncSamp, ProfEncMtf, ProfEncNorm, ProfEncRans]));
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
  BlockSize, OrigSize, PayloadLen, Method, BwtSize, Primary, TokenCount,
    NSamples, i, MaxSamples: Int32;
  Freq: array[0..MTF_CONTEXTS * MTF_SYMBOLS - 1] of Int32;
  Crc: LongWord;
  TBlock, TStage: TDateTime;
  R, HH: Int32;
begin
  Result := False;
  Stats.InBytes := 0;
  Stats.OutBytes := 0;
  Stats.Blocks := 0;
  Stats.RawBlocks := 0;
  ProfOn := GetEnvironmentVariable('TVCT_PROFILE') <> '';
  ProfRans := 0; ProfMtf := 0; ProfBwt := 0;
  ProfEncSA := 0; ProfEncBwt := 0; ProfEncSamp := 0; ProfEncMtf := 0; ProfEncNorm := 0; ProfEncRans := 0;
  ProfRead := 0; ProfCrc := 0; ProfMove := 0; ProfWrite := 0; ProfTotal := 0;
  

  ReadExact(Src, @Hdr[0], CODEC_HEADER_SIZE);
  if (Hdr[0] <> Ord('T')) or (Hdr[1] <> Ord('V')) or (Hdr[2] <> Ord('C')) or
     (Hdr[3] <> Ord('T')) or (Hdr[4] <> CODEC_VERSION) then
    Exit;
  BlockSize := 1 shl Hdr[5];
  if (BlockSize < 1 shl 16) or (BlockSize > 1 shl 27) then
    Exit;

  Buf := GetMem(BlockSize * 2 + 64);
  OutBuf := GetMem(BlockSize);
  MaxSamples := BlockSize div SAMPLE_RATE + 2;
  Samples := GetMem(MaxSamples * SizeOf(Int32));
  try
    TBlock := Now;
    while Src.Position < Src.Size do
    begin
      TStage := Now;
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
        ReadExact(Src, OutBuf, OrigSize);
      end
      else if (Method = METHOD_BWT) or (Method = METHOD_CM) then
      begin
        ReadExact(Src, @Blk[0], BWT_HEADER_EXTRA);
        BwtSize := Int32(GetU32(@Blk[0]));
        Primary := Int32(GetU32(@Blk[4]));
        TokenCount := Int32(GetU32(@Blk[8]));
        NSamples := Int32(GetU32(@Blk[12]));
        if (NSamples <= 0) or (NSamples > MaxSamples) then
          Exit;
        if Method = METHOD_BWT then
          for i := 0 to MTF_CONTEXTS * MTF_SYMBOLS - 1 do
          begin
            ReadExact(Src, @Blk[0], 2);
            Freq[i] := Int32(Blk[0]) or (Int32(Blk[1]) shl 8);
          end;
        ReadExact(Src, Samples, NSamples * SizeOf(Int32));
        if PayloadLen + OrigSize > BlockSize * 2 + 64 then
          Exit;
        ProfRead := ProfRead + (Now - TStage) * SecsPerDay;
        TStage := Now;
        ReadExact(Src, Buf, PayloadLen);
        ProfRead := ProfRead + (Now - TStage) * SecsPerDay;
        TStage := Now;
        if not DecompressBlock(Buf, PayloadLen, OrigSize, @Freq[0], BwtSize,
                               Primary, TokenCount, NSamples,
                               PInt32(Samples), OutBuf, Method) then
          Exit;
        ProfMove := ProfMove + (Now - TStage) * SecsPerDay;
        TStage := Now;
        Move(Buf[PayloadLen], Buf[0], OrigSize);
        ProfMove := ProfMove + (Now - TStage) * SecsPerDay;
        TStage := Now;
      end
      else
        Exit;

      ProfCrc := ProfCrc + (Now - TStage) * SecsPerDay;
      TStage := Now;
      if Crc32c(0, OutBuf[0], OrigSize) <> Crc then
        Exit;
      Dst.WriteBuffer(OutBuf[0], OrigSize);
      ProfWrite := ProfWrite + (Now - TStage) * SecsPerDay;
      Inc(Stats.Blocks);
      Inc(Stats.OutBytes, OrigSize);
      Inc(Stats.InBytes, BLOCK_HEADER_SIZE + PayloadLen);
    end;
    Result := True;
    if ProfOn then
      WriteLn(StdErr, Format('profile: rans %.2fs mtf %.2fs bwt %.2fs read %.2fs move %.2fs crc %.2fs write %.2fs total %.2fs',
        [ProfRans, ProfMtf, ProfBwt, ProfRead, ProfMove, ProfCrc, ProfWrite, (Now - TBlock) * SecsPerDay]));
  finally
    FreeMem(Samples);
    FreeMem(OutBuf);
    FreeMem(Buf);
  end;
end;

initialization
  InitCtxTab;

end.
