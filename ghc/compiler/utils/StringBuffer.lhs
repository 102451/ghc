%
% (c) The University of Glasgow, 1997-2003
%
\section{String buffers}

Buffers for scanning string input stored in external arrays.

\begin{code}
{-# OPTIONS_GHC -O #-}
-- always optimise this module, it's critical

module StringBuffer
       (
        StringBuffer(..),
	-- non-abstract for vs\/HaskellService

	 -- * Creation\/destruction
        hGetStringBuffer,
	stringToStringBuffer,

	-- * Inspection
	nextChar,
	currentChar,
	prevChar,
	atEnd,

	-- * Moving and comparison
	stepOn,
	offsetBytes,
	byteDiff,

        -- * Conversion
        lexemeToString,
        lexemeToFastString,

	 -- * Parsing integers
	parseInteger,
       ) where

#include "HsVersions.h"

import Encoding
import FastString	(FastString,mkFastString,mkFastStringBytes)

import GLAEXTS

import Foreign

import GHC.IOBase		( IO(..) )
import GHC.Base			( unsafeChr )

import System.IO		( hGetBuf )

import IO			( hFileSize, IOMode(ReadMode),
				  hClose )
#if __GLASGOW_HASKELL__ >= 601
import System.IO		( openBinaryFile )
#else
import IOExts                   ( openFileEx, IOModeEx(..) )
#endif

#if __GLASGOW_HASKELL__ < 601
openBinaryFile fp mode = openFileEx fp (BinaryMode mode)
#endif

-- -----------------------------------------------------------------------------
-- The StringBuffer type

-- |A StringBuffer is an internal pointer to a sized chunk of bytes.
-- The bytes are intended to be *immutable*.  There are pure
-- operations to read the contents of a StringBuffer.
--
-- A StringBuffer may have a finalizer, depending on how it was
-- obtained.
--
data StringBuffer
 = StringBuffer {
     buf :: {-# UNPACK #-} !(ForeignPtr Word8),
     len :: {-# UNPACK #-} !Int, 	-- length
     cur :: {-# UNPACK #-} !Int		-- current pos
  }
	-- The buffer is assumed to be UTF-8 encoded, and furthermore
	-- we add three '\0' bytes to the end as sentinels so that the
	-- decoder doesn't have to check for overflow at every single byte
	-- of a multibyte sequence.

instance Show StringBuffer where
	showsPrec _ s = showString "<stringbuffer(" 
		      . shows (len s) . showString "," . shows (cur s)
		      . showString ">"

-- -----------------------------------------------------------------------------
-- Creation / Destruction

hGetStringBuffer :: FilePath -> IO StringBuffer
hGetStringBuffer fname = do
   h <- openBinaryFile fname ReadMode
   size_i <- hFileSize h
   let size = fromIntegral size_i
   buf <- mallocForeignPtrArray (size+3)
   withForeignPtr buf $ \ptr -> do
     r <- if size == 0 then return 0 else hGetBuf h ptr size
     hClose h
     if (r /= size)
	then ioError (userError "short read of file")
	else do
	  pokeArray (ptr `plusPtr` size :: Ptr Word8) [0,0,0]
		 -- sentinels for UTF-8 decoding
	  return (StringBuffer buf size 0)

stringToStringBuffer :: String -> IO StringBuffer
stringToStringBuffer str = do
  let size = utf8EncodedLength str
  buf <- mallocForeignPtrArray (size+3)
  withForeignPtr buf $ \ptr -> do
    utf8EncodeString ptr str
    pokeArray (ptr `plusPtr` size :: Ptr Word8) [0,0,0]
	 -- sentinels for UTF-8 decoding
  return (StringBuffer buf size 0)

-- -----------------------------------------------------------------------------
-- Grab a character

-- Getting our fingers dirty a little here, but this is performance-critical
{-# INLINE nextChar #-}
nextChar :: StringBuffer -> (Char,StringBuffer)
nextChar (StringBuffer buf len (I# cur#)) =
  inlinePerformIO $ do
    withForeignPtr buf $ \(Ptr a#) -> do
	case utf8DecodeChar# (a# `plusAddr#` cur#) of
	  (# c#, b# #) ->
	     let cur' = I# (b# `minusAddr#` a#) in
	     return (C# c#, StringBuffer buf len cur')

currentChar :: StringBuffer -> Char
currentChar = fst . nextChar

prevChar :: StringBuffer -> Char -> Char
prevChar (StringBuffer buf len 0)   deflt = deflt
prevChar (StringBuffer buf len cur) deflt = 
  inlinePerformIO $ do
    withForeignPtr buf $ \p -> do
      p' <- utf8PrevChar (p `plusPtr` cur)
      return (fst (utf8DecodeChar p'))

-- -----------------------------------------------------------------------------
-- Moving

stepOn :: StringBuffer -> StringBuffer
stepOn s = snd (nextChar s)

offsetBytes :: Int -> StringBuffer -> StringBuffer
offsetBytes i s = s { cur = cur s + i }

byteDiff :: StringBuffer -> StringBuffer -> Int
byteDiff s1 s2 = cur s2 - cur s1

atEnd :: StringBuffer -> Bool
atEnd (StringBuffer _ l c) = l == c

-- -----------------------------------------------------------------------------
-- Conversion

lexemeToString :: StringBuffer -> Int {-bytes-} -> String
lexemeToString _ 0 = ""
lexemeToString (StringBuffer buf _ cur) bytes =
  inlinePerformIO $ 
    withForeignPtr buf $ \ptr -> 
      utf8DecodeString (ptr `plusPtr` cur) bytes

lexemeToFastString :: StringBuffer -> Int {-bytes-} -> FastString
lexemeToFastString _ 0 = mkFastString ""
lexemeToFastString (StringBuffer buf _ cur) len =
   inlinePerformIO $
     withForeignPtr buf $ \ptr ->
       return $! mkFastStringBytes (ptr `plusPtr` cur) len

-- -----------------------------------------------------------------------------
-- Parsing integer strings in various bases

byteOff :: StringBuffer -> Int -> Char
byteOff (StringBuffer buf _ cur) i = 
  inlinePerformIO $ withForeignPtr buf $ \ptr -> do
    w <- peek (ptr `plusPtr` (cur+i))
    return (unsafeChr (fromIntegral (w::Word8)))

-- | XXX assumes ASCII digits only
parseInteger :: StringBuffer -> Int -> Integer -> (Char->Int) -> Integer
parseInteger buf len radix to_int 
  = go 0 0
  where go i x | i == len  = x
	       | otherwise = go (i+1) (x * radix + toInteger (to_int (byteOff buf i)))

-- -----------------------------------------------------------------------------
-- under the carpet

-- Just like unsafePerformIO, but we inline it.
{-# INLINE inlinePerformIO #-}
inlinePerformIO :: IO a -> a
inlinePerformIO (IO m) = case m realWorld# of (# _, r #)   -> r

\end{code}
