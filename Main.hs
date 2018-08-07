{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Control.Monad                    (forM, forM_, replicateM,
                                                   unless, when)
import           Control.Monad.IO.Class           (MonadIO, liftIO)
import           Control.Monad.Trans.Class        (lift)
import           Control.Monad.Trans.Resource     (MonadResource, runResourceT)
import qualified Control.Monad.Trans.State        as S
import           Data.Binary.Get
import           Data.Bits
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as B8
import qualified Data.ByteString.Lazy             as BL
import           Data.Char                        (isAlphaNum)
import           Data.Conduit                     ((.|))
import qualified Data.Conduit                     as C
import qualified Data.Conduit.Audio               as A
import qualified Data.Conduit.Audio.SampleRate    as SR
import qualified Data.Conduit.List                as CL
import qualified Data.EventList.Absolute.TimeBody as ATB
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Int
import           Data.List                        (intercalate)
import           Data.Maybe                       (fromMaybe)
import qualified Data.Vector.Storable             as V
import qualified Data.Vector.Storable.Mutable     as MV
import           Data.Word
import           GHC.IO.Handle                    (HandlePosn (..))
import           Numeric
import qualified Numeric.NonNegative.Class        as NNC
import qualified Sound.MIDI.File.Event            as E
import qualified Sound.MIDI.File.Load             as Load
import qualified Sound.MIDI.Message.Channel       as EC
import qualified Sound.MIDI.Message.Channel.Voice as ECV
import qualified Sound.MIDI.Util                  as U
import           System.Directory                 (createDirectoryIfMissing)
import           System.Environment               (getArgs)
import           System.FilePath                  (dropExtension, (-<.>), (<.>),
                                                   (</>))
import qualified System.IO                        as IO

data SAMPEntry = SAMPEntry
  { sampChannels     :: Int -- guessing
  , sampRate         :: Int
  , sampFilePosition :: Int
  } deriving (Eq, Show)

data SDESEntry = SDESEntry
  { sdesNoteNumber :: Int
  , sdesSAMPNumber :: Int
  -- lots of other parts not deciphered yet
  } deriving (Eq, Show)

data INSTEntry = INSTEntry
  { instProgNumber :: Int
  , instSDESCount  :: Int
  -- other parts not deciphered yet
  } deriving (Eq, Show)

data Chunk
  = SAMP [SAMPEntry] -- samples
  | SANM [B.ByteString] -- sample names
  | SAFN [B.ByteString] -- sample filenames
  | BANK B.ByteString -- bank(s?)
  | BKNM B.ByteString -- bank name
  | INST [INSTEntry] -- instruments
  | INNM [B.ByteString] -- instrument names
  | SDES [SDESEntry] -- sample... directives?
  | SDNM [B.ByteString] -- SDES names
  -- | Unknown B.ByteString BL.ByteString
  deriving (Eq, Show)

getSAMPEntry :: Get SAMPEntry
getSAMPEntry = do
  0x12 <- getWord32le -- no idea what this is
  chans <- getWord32le -- guessing this is channels, all 1 in file i'm looking at now
  rate <- getWord32le
  0 <- getWord32le -- dunno what this space is for
  0 <- getWord16le
  posn <- getWord32le
  return $ SAMPEntry (fromIntegral chans) (fromIntegral rate) (fromIntegral posn)

getSDESEntry :: Get SDESEntry
getSDESEntry = do
  -- comments are observed values
  _ <- getWord32le -- 0x1d
  _ <- getWord32le -- 3
  note <- getWord8
  _ <- getWord8 -- same as note
  _ <- getWord8 -- same as note
  _ <- getByteString 15 -- lots of unknown stuff
  samp <- getWord8
  _ <- getByteString 6 -- all 0
  return $ SDESEntry (fromIntegral note) (fromIntegral samp)

getINSTEntry :: Get INSTEntry
getINSTEntry = do
  -- comments are observed values
  _ <- getWord32le -- 0xC
  _ <- getWord32le -- 1
  prog <- getWord16le
  _ <- getWord16le -- unknown
  _ <- getWord16le -- 0
  sdes <- getWord16le -- number of SDES entries for this instrument
  return $ INSTEntry (fromIntegral prog) (fromIntegral sdes)

getSAMP :: Word32 -> Get [SAMPEntry]
getSAMP n = case quotRem n 22 of
  (samps, 0) -> replicateM (fromIntegral samps) getSAMPEntry
  _          -> fail $ "SAMP length of " <> show n <> " not divisible by 22"

getINST :: Word32 -> Get [INSTEntry]
getINST n = case quotRem n 16 of
  (insts, 0) -> replicateM (fromIntegral insts) getINSTEntry
  _          -> fail $ "SAMP length of " <> show n <> " not divisible by 16"

getSDES :: Word32 -> Get [SDESEntry]
getSDES n = case quotRem n 33 of
  (insts, 0) -> replicateM (fromIntegral insts) getSDESEntry
  _          -> fail $ "SDES length of " <> show n <> " not divisible by 33"

getString :: Get B.ByteString
getString = do
  len <- getWord32le
  getByteString $ fromIntegral len

getStringList :: Word32 -> Get [B.ByteString]
getStringList n = do
  endPosn <- (+ fromIntegral n) <$> bytesRead
  1 <- getWord32le -- dunno what this is
  let go = bytesRead >>= \br -> case compare br endPosn of
        EQ -> return []
        LT -> do
          str <- getString
          (str :) <$> go
        GT -> fail "SANM/SAFN went over its chunk length"
  go

riffChunks :: Get [Chunk]
riffChunks = isEmpty >>= \case
  True -> return []
  False -> do
    ctype <- getByteString 4
    size <- getWord32le
    chunk <- case ctype of
      "SAMP" -> SAMP <$> getSAMP size
      "SANM" -> SANM <$> getStringList size
      "SAFN" -> SAFN <$> getStringList size
      "BANK" -> BANK <$> getByteString (fromIntegral size)
      "BKNM" -> do
        1 <- getWord32le -- dunno
        BKNM <$> getString
      "INST" -> INST <$> getINST size
      "INNM" -> INNM <$> getStringList size
      "SDES" -> SDES <$> getSDES size
      "SDNM" -> SDNM <$> getStringList size
      _ -> fail $ "Unknown chunk type " <> show ctype
    (chunk :) <$> riffChunks

_showByteString :: B.ByteString -> String
_showByteString = intercalate " " . map showByte . B.unpack where
  showByte n = if n < 0x10 then '0' : showHex n "" else showHex n ""

vagFilter :: [(Double, Double)]
vagFilter =
  [ (0.0, 0.0)
  , (60.0 / 64.0,  0.0)
  , (115.0 / 64.0, -52.0 / 64.0)
  , (98.0 / 64.0, -55.0 / 64.0)
  , (122.0 / 64.0, -60.0 / 64.0)
  ]

decodeVAGBlock :: S.StateT (Double, Double) Get [Int16]
decodeVAGBlock = do
  bytes <- lift $ getByteString 16
  let predictor = B.index bytes 0 `shiftR` 4 -- high nibble, shouldn't be more than 4
      shift'    = B.index bytes 0 .&. 0xF    -- low  nibble
      channel   = B.index bytes 1
      samples = do
        byte <- B.unpack $ B.drop 2 bytes
        let signExtend :: Word32 -> Int32
            signExtend x = fromIntegral $ if (x .&. 0x8000) /= 0 then x .|. 0xFFFF0000 else x
            ss0 = signExtend $ (fromIntegral byte .&. 0xF ) `shiftL` 12
            ss1 = signExtend $ (fromIntegral byte .&. 0xF0) `shiftL` 8
        [   realToFrac $ ss0 `shiftR` fromIntegral shift'
          , realToFrac $ ss1 `shiftR` fromIntegral shift'
          ]
  if channel == 7
    then return []
    else forM samples $ \sample -> do
      (s0, s1) <- S.get
      let newSample = sample
            + s0 * fst (vagFilter !! fromIntegral predictor)
            + s1 * snd (vagFilter !! fromIntegral predictor)
      S.put (newSample, s0)
      -- TODO do we need to clamp this
      return $ round newSample

decodeSamples :: BL.ByteString -> [Int16]
decodeSamples bs = let
  go = decodeVAGBlock >>= \case
    []    -> return []
    block -> (block ++) <$> go
  in flip runGet bs $ do
    getByteString 16 >>= \firstRow -> if B.all (== 0) firstRow
      then return ()
      else fail "first row of VAG block not all zero"
    S.evalStateT go (0, 0)

writeWAV :: (MonadResource m) => FilePath -> A.AudioSource m Int16 -> m ()
writeWAV fp (A.AudioSource s r c _) = C.runConduit $ s .| C.bracketP
  (IO.openBinaryFile fp IO.WriteMode)
  IO.hClose
  (\h -> do
    let chunk ctype f = do
          let getPosn = liftIO $ IO.hGetPosn h
          liftIO $ B.hPut h ctype
          lenPosn <- getPosn
          liftIO $ B.hPut h $ B.pack [0xDE, 0xAD, 0xBE, 0xEF] -- filled in later
          HandlePosn _ start <- getPosn
          x <- f
          endPosn@(HandlePosn _ end) <- getPosn
          liftIO $ do
            IO.hSetPosn lenPosn
            writeLE h (fromIntegral $ end - start :: Word32)
            IO.hSetPosn endPosn
          return x
    chunk "RIFF" $ do
      liftIO $ B.hPut h "WAVE"
      chunk "fmt " $ liftIO $ do
        writeLE h (1                            :: Word16) -- 1 is PCM
        writeLE h (fromIntegral c               :: Word16) -- channels
        writeLE h (floor r                      :: Word32) -- sample rate
        writeLE h (floor r * fromIntegral c * 2 :: Word32) -- avg. bytes per second = rate * block align
        writeLE h (fromIntegral c * 2           :: Word16) -- block align = chans * (bps / 8)
        writeLE h (16                           :: Word16) -- bits per sample
      chunk "data" $ CL.mapM_ $ \v -> liftIO $ do
        V.forM_ v $ writeLE h
  )

class LE a where
  writeLE :: IO.Handle -> a -> IO ()

instance LE Word32 where
  writeLE h w = B.hPut h $ B.pack [a, b, c, d] where
    a = fromIntegral w
    b = fromIntegral $ w `shiftR` 8
    c = fromIntegral $ w `shiftR` 16
    d = fromIntegral $ w `shiftR` 24

instance LE Word16 where
  writeLE h w = B.hPut h $ B.pack [a, b] where
    a = fromIntegral w
    b = fromIntegral $ w `shiftR` 8

instance LE Int32 where
  writeLE h w = writeLE h (fromIntegral w :: Word32)

instance LE Int16 where
  writeLE h w = writeLE h (fromIntegral w :: Word16)

trackState :: (NNC.C t) => s -> (s -> t -> a -> (s, Maybe b)) -> RTB.T t a -> RTB.T t b
trackState curState step rtb = case RTB.viewL rtb of
  Nothing -> RTB.empty
  Just ((dt, x), rtb') -> case step curState dt x of
    (nextState, Nothing) -> RTB.delay dt   $ trackState nextState step rtb'
    (nextState, Just y ) -> RTB.cons  dt y $ trackState nextState step rtb'

applyStatus1 :: (NNC.C t, Ord s, Ord a) => s -> RTB.T t s -> RTB.T t a -> RTB.T t (s, a)
applyStatus1 start status events = let
  fn current _ = \case
    Left  s -> (s      , Nothing          )
    Right x -> (current, Just (current, x))
  in trackState start fn $ RTB.merge (fmap Left status) (fmap Right events)

renderSamples :: (MonadResource m, MonadIO n) => RTB.T U.Seconds (Int, V.Vector Int16) -> m (A.AudioSource n Int16)
renderSamples rtb = do
  let samps = ATB.toPairList $ RTB.toAbsoluteEventList 0 rtb
      outputRate = 48000 :: Double
  mv <- liftIO $ MV.new $ floor $ 6 * 60 * outputRate
  liftIO $ MV.set mv 0
  forM_ samps $ \(secs, (inputRate, v)) -> do
    let src
          = SR.resampleTo outputRate SR.SincMediumQuality
          $ A.mapSamples A.fractionalSample
          $ A.AudioSource (C.yield v) (realToFrac inputRate) 1 $ V.length v
        writeToPosn framePosn = C.await >>= \case
          Nothing -> return ()
          Just v' -> do
            currentArea <- liftIO $ V.freeze $ MV.slice framePosn (V.length v') mv
            let mixed = V.zipWith (+) currentArea v'
            liftIO $ V.copy (MV.slice framePosn (V.length mixed) mv) mixed
            writeToPosn $ framePosn + V.length v'
    C.runConduit $ A.source src .| writeToPosn (floor $ realToFrac secs * outputRate)
  v <- liftIO $ V.unsafeFreeze mv
  return $ A.mapSamples (A.integralSample . (* 0.5)) $ A.AudioSource (C.yield v) outputRate 1 $ V.length v

main :: IO ()
main = getArgs >>= \case
  "stems" : midPath : bnkPaths -> do
    Left trks <- U.decodeFile <$> Load.fromFile midPath
    sounds <- forM bnkPaths $ \bnkPath -> do
      bnk <- BL.fromStrict <$> B.readFile bnkPath
      nse <- BL.fromStrict <$> B.readFile (bnkPath -<.> "nse")
      return (runGet riffChunks bnk, nse)
    let tmap = U.makeTempoMap $ head trks
    forM_ (zip [0..] $ tail trks) $ \(i, trk) -> let
      soundNotes = flip RTB.mapMaybe trk $ \case
        E.MIDIEvent (EC.Cons _ (EC.Voice (ECV.NoteOn p v)))
          | ECV.fromPitch p < 96 && ECV.fromVelocity v /= 0
          -> Just $ ECV.fromPitch p
        _ -> Nothing
      bankChanges = flip RTB.mapMaybe trk $ \case
        E.MIDIEvent (EC.Cons _ (EC.Voice (ECV.Control cont v)))
          | ECV.fromController cont == 0
          -> Just v
        _ -> Nothing
      progChanges = flip RTB.mapMaybe trk $ \case
        E.MIDIEvent (EC.Cons _ (EC.Voice (ECV.ProgramChange prog)))
          -> Just $ ECV.fromProgram prog
        _ -> Nothing
      applied
        = applyStatus1 Nothing (fmap Just bankChanges)
        $ applyStatus1 Nothing (fmap Just progChanges)
        $ soundNotes
      appliedSources = flip RTB.mapMaybe applied $ \case
        (Just bank, (Just prog, pitch)) -> Just $ let
          (chunks, nse) = sounds !! (bank - 1)
          insts = concat [ xs | INST xs <- chunks ]
          (skipInsts, inst : _) = break ((== prog) . instProgNumber) insts
          skipSDES = sum $ map instSDESCount skipInsts
          sdeses = take (instSDESCount inst) $ drop skipSDES $ concat [ xs | SDES xs <- chunks ]
          sdes = head [ sd | sd <- sdeses, sdesNoteNumber sd == pitch ]
          samp = concat [ xs | SAMP xs <- chunks ] !! sdesSAMPNumber sdes
          bytes = BL.drop (fromIntegral $ sampFilePosition samp) nse
          samples = V.fromList $ decodeSamples bytes
          in (sampRate samp, samples)
        _ -> Nothing
      in unless (RTB.null appliedSources) $ do
        let name = concat
              [ if (i :: Int) < 10 then '0' : show i else show i
              , "_"
              , map (\c -> if isAlphaNum c then c else '_') $ fromMaybe "" $ U.trackName trk
              , ".wav"
              ]
        audio <- runResourceT $ renderSamples $ U.applyTempoTrack tmap appliedSources
        runResourceT $ writeWAV name audio
  ["print", bnkPath] -> do
    bnk <- BL.fromStrict <$> B.readFile bnkPath
    let chunks = runGet riffChunks bnk
    forM_ (zip (concat [xs | SDES xs <- chunks]) (concat [xs | SDNM xs <- chunks])) $ \(ent, name) -> do
      print name
      print ent
    forM_ (zip (concat [xs | SAMP xs <- chunks]) (concat [xs | SANM xs <- chunks])) $ \(ent, name) -> do
      print name
      print ent
  "bnk" : bnks -> forM_ bnks $ \bnkPath -> do
    bnk <- BL.fromStrict <$> B.readFile bnkPath
    nse <- BL.fromStrict <$> B.readFile (bnkPath -<.> "nse")
    let outDir = dropExtension bnkPath ++ "_samples"
    createDirectoryIfMissing False outDir
    let chunks = runGet riffChunks bnk
        samp = concat [ xs | SAMP xs <- chunks ]
        sanm = concat [ xs | SANM xs <- chunks ]
    forM_ (zip samp sanm) $ \(entry, name) -> do
      let bytes = BL.drop (fromIntegral $ sampFilePosition entry) nse
          samples = V.fromList $ decodeSamples bytes
      when (sampRate entry /= 0) $ do
        -- BL.writeFile (outDir </> B8.unpack name <.> "bin") bytes
        print (entry, name)
        runResourceT $ writeWAV (outDir </> B8.unpack name <.> "wav") $ A.AudioSource
          (C.yield samples)
          (realToFrac $ sampRate entry)
          1
          (V.length samples)
  _ -> error "incorrect usage"
