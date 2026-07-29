{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}

-- | Pure bytestring wrappers over the vendored bzip2 1.0.8 codec.
--
-- The public shape matches @zlib@'s pure compression API.  The underlying C
-- calls allocate fresh output buffers and copy their results before returning,
-- so the controlled 'unsafePerformIO' boundary does not expose mutable state.
module Tungsten.BZip2
  ( compress
  , decompress
  ) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Foreign.C.Types (CChar, CInt (..), CUInt (..))
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek, poke)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall unsafe "BZ2_bzBuffToBuffCompress"
  c_bzCompress
    :: Ptr CChar
    -> Ptr CUInt
    -> Ptr CChar
    -> CUInt
    -> CInt
    -> CInt
    -> CInt
    -> IO CInt

foreign import ccall unsafe "BZ2_bzBuffToBuffDecompress"
  c_bzDecompress
    :: Ptr CChar
    -> Ptr CUInt
    -> Ptr CChar
    -> CUInt
    -> CInt
    -> CInt
    -> IO CInt

bzOk, bzOutputBufferFull :: CInt
bzOk = 0
bzOutputBufferFull = -8

-- | Compress one strict bytestring as a level-nine bzip2 stream.
compress :: BS.ByteString -> BS.ByteString
compress source = unsafePerformIO $
  BS.useAsCStringLen source $ \(sourcePointer, sourceLength) -> do
    encodedLength <- checkedLength "compression input" sourceLength
    let outputCapacity = sourceLength + sourceLength `div` 100 + 601
    withOutputBuffer outputCapacity $ \outputPointer outputLengthPointer -> do
      status <-
        c_bzCompress
          outputPointer
          outputLengthPointer
          sourcePointer
          encodedLength
          9
          0
          30
      pure status
{-# NOINLINE compress #-}

-- | Decompress one strict bzip2 stream, growing the destination buffer until
-- libbzip2 reports that the complete stream fits.
decompress :: BS.ByteString -> BS.ByteString
decompress source = unsafePerformIO $
  BS.useAsCStringLen source $ \(sourcePointer, sourceLength) -> do
    encodedLength <- checkedLength "decompression input" sourceLength
    let initialCapacity = max 1024 (sourceLength * 6)
    decodeWithCapacity sourcePointer encodedLength initialCapacity
{-# NOINLINE decompress #-}

decodeWithCapacity :: Ptr CChar -> CUInt -> Int -> IO BS.ByteString
decodeWithCapacity sourcePointer sourceLength outputCapacity = do
  result <-
    withOutputBufferStatus outputCapacity $ \outputPointer outputLengthPointer ->
      c_bzDecompress
        outputPointer
        outputLengthPointer
        sourcePointer
        sourceLength
        0
        0
  case result of
    (status, output)
      | status == bzOk -> pure output
      | status == bzOutputBufferFull ->
          let nextCapacity = outputCapacity * 2
           in if nextCapacity <= outputCapacity
                then codecFailure "decompression output exceeds addressable memory" status
                else decodeWithCapacity sourcePointer sourceLength nextCapacity
      | otherwise -> codecFailure "decompression" status

withOutputBuffer
  :: Int
  -> (Ptr CChar -> Ptr CUInt -> IO CInt)
  -> IO BS.ByteString
withOutputBuffer capacity action = do
  (status, output) <- withOutputBufferStatus capacity action
  requireSuccess "compression" status
  pure output

withOutputBufferStatus
  :: Int
  -> (Ptr CChar -> Ptr CUInt -> IO CInt)
  -> IO (CInt, BS.ByteString)
withOutputBufferStatus capacity action = do
  encodedCapacity <- checkedLength "output buffer" capacity
  bracket (mallocBytes capacity) free $ \outputPointer ->
    with encodedCapacity $ \outputLengthPointer -> do
      poke outputLengthPointer encodedCapacity
      status <- action outputPointer outputLengthPointer
      outputLength <- peek outputLengthPointer
      output <-
        if status `elem` [bzOk, bzOutputBufferFull]
          then BS.packCStringLen (outputPointer, fromIntegral outputLength)
          else pure BS.empty
      pure (status, output)

checkedLength :: String -> Int -> IO CUInt
checkedLength description value
  | value < 0 || toInteger value > toInteger (maxBound :: CUInt) =
      ioError (userError ("bzip2 " <> description <> " exceeds the 32-bit codec limit"))
  | otherwise = pure (fromIntegral value)

requireSuccess :: String -> CInt -> IO ()
requireSuccess _ status | status == bzOk = pure ()
requireSuccess operation status = codecFailure operation status

codecFailure :: String -> CInt -> IO value
codecFailure operation status =
  ioError (userError ("bzip2 " <> operation <> " failed with status " <> show status))
