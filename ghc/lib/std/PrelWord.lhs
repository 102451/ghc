%
% (c) The University of Glasgow, 1997-2001
%
\section[PrelWord]{Module @PrelWord@}

\begin{code}
#include "MachDeps.h"

module PrelWord (
    Word(..), Word8(..), Word16(..), Word32(..), Word64(..),
    divZeroError, toEnumError, fromEnumError, succError, predError)
    where

import PrelBase
import PrelEnum
import PrelNum
import PrelReal
import PrelRead
import PrelArr
import PrelBits

------------------------------------------------------------------------
-- Helper functions
------------------------------------------------------------------------

{-# NOINLINE divZeroError #-}
divZeroError :: (Show a) => String -> a -> b
divZeroError meth x =
    error $ "Integral." ++ meth ++ ": divide by 0 (" ++ show x ++ " / 0)"

{-# NOINLINE toEnumError #-}
toEnumError :: (Show a) => String -> Int -> (a,a) -> b
toEnumError inst_ty i bnds =
    error $ "Enum.toEnum{" ++ inst_ty ++ "}: tag (" ++
            show i ++
            ") is outside of bounds " ++
            show bnds

{-# NOINLINE fromEnumError #-}
fromEnumError :: (Show a) => String -> a -> b
fromEnumError inst_ty x =
    error $ "Enum.fromEnum{" ++ inst_ty ++ "}: value (" ++
            show x ++
            ") is outside of Int's bounds " ++
            show (minBound::Int, maxBound::Int)

{-# NOINLINE succError #-}
succError :: String -> a
succError inst_ty =
    error $ "Enum.succ{" ++ inst_ty ++ "}: tried to take `succ' of maxBound"

{-# NOINLINE predError #-}
predError :: String -> a
predError inst_ty =
    error $ "Enum.pred{" ++ inst_ty ++ "}: tried to take `pred' of minBound"

------------------------------------------------------------------------
-- type Word
------------------------------------------------------------------------

-- A Word is an unsigned integral type, with the same size as Int.

data Word = W# Word# deriving (Eq, Ord)

instance CCallable Word
instance CReturnable Word

instance Show Word where
    showsPrec p x = showsPrec p (toInteger x)

instance Num Word where
    (W# x#) + (W# y#)      = W# (x# `plusWord#` y#)
    (W# x#) - (W# y#)      = W# (x# `minusWord#` y#)
    (W# x#) * (W# y#)      = W# (x# `timesWord#` y#)
    negate (W# x#)         = W# (int2Word# (negateInt# (word2Int# x#)))
    abs x                  = x
    signum 0               = 0
    signum _               = 1
    fromInteger (S# i#)    = W# (int2Word# i#)
    fromInteger (J# s# d#) = W# (integer2Word# s# d#)

instance Real Word where
    toRational x = toInteger x % 1

instance Enum Word where
    succ x
        | x /= maxBound = x + 1
        | otherwise     = succError "Word"
    pred x
        | x /= minBound = x - 1
        | otherwise     = predError "Word"
    toEnum i@(I# i#)
        | i >= 0        = W# (int2Word# i#)
        | otherwise     = toEnumError "Word" i (minBound::Word, maxBound::Word)
    fromEnum x@(W# x#)
        | x <= fromIntegral (maxBound::Int)
                        = I# (word2Int# x#)
        | otherwise     = fromEnumError "Word" x
    enumFrom            = integralEnumFrom
    enumFromThen        = integralEnumFromThen
    enumFromTo          = integralEnumFromTo
    enumFromThenTo      = integralEnumFromThenTo

instance Integral Word where
    quot    x@(W# x#) y@(W# y#)
        | y /= 0                = W# (x# `quotWord#` y#)
        | otherwise             = divZeroError "quot{Word}" x
    rem     x@(W# x#) y@(W# y#)
        | y /= 0                = W# (x# `remWord#` y#)
        | otherwise             = divZeroError "rem{Word}" x
    div     x@(W# x#) y@(W# y#)
        | y /= 0                = W# (x# `quotWord#` y#)
        | otherwise             = divZeroError "div{Word}" x
    mod     x@(W# x#) y@(W# y#)
        | y /= 0                = W# (x# `remWord#` y#)
        | otherwise             = divZeroError "mod{Word}" x
    quotRem x@(W# x#) y@(W# y#)
        | y /= 0                = (W# (x# `quotWord#` y#), W# (x# `remWord#` y#))
        | otherwise             = divZeroError "quotRem{Word}" x
    divMod  x@(W# x#) y@(W# y#)
        | y /= 0                = (W# (x# `quotWord#` y#), W# (x# `remWord#` y#))
        | otherwise             = divZeroError "divMod{Word}" x
    toInteger (W# x#)
        | i# >=# 0#             = S# i#
        | otherwise             = case word2Integer# x# of (# s, d #) -> J# s d
        where
        i# = word2Int# x#

instance Bounded Word where
    minBound = 0
#if WORD_SIZE_IN_BYTES == 4
    maxBound = 0xFFFFFFFF
#else
    maxBound = 0xFFFFFFFFFFFFFFFF
#endif

instance Ix Word where
    range (m,n)       = [m..n]
    index b@(m,_) i
        | inRange b i = fromIntegral (i - m)
        | otherwise   = indexError b i "Word"
    inRange (m,n) i   = m <= i && i <= n

instance Read Word where
    readsPrec p s = [(fromInteger x, r) | (x, r) <- readsPrec p s]

instance Bits Word where
    (W# x#) .&.   (W# y#)    = W# (x# `and#` y#)
    (W# x#) .|.   (W# y#)    = W# (x# `or#`  y#)
    (W# x#) `xor` (W# y#)    = W# (x# `xor#` y#)
    complement (W# x#)       = W# (x# `xor#` mb#) where W# mb# = maxBound
    (W# x#) `shift` (I# i#)
        | i# >=# 0#          = W# (x# `shiftL#` i#)
        | otherwise          = W# (x# `shiftRL#` negateInt# i#)
#if WORD_SIZE_IN_BYTES == 4
    (W# x#) `rotate` (I# i#) = W# ((x# `shiftL#` i'#) `or#` (x# `shiftRL#` (32# -# i'#)))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 31#)
#else
    (W# x#) `rotate` (I# i#) = W# ((x# `shiftL#` i'#) `or#` (x# `shiftRL#` (64# -# i'#)))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 63#)
#endif
    bitSize  _               = WORD_SIZE_IN_BYTES * 8
    isSigned _               = False

{-# RULES
"fromIntegral/Int->Word"  fromIntegral = \(I# x#) -> W# (int2Word# x#)
"fromIntegral/Word->Int"  fromIntegral = \(W# x#) -> I# (word2Int# x#)
"fromIntegral/Word->Word" fromIntegral = id :: Word -> Word
    #-}

------------------------------------------------------------------------
-- type Word8
------------------------------------------------------------------------

-- Word8 is represented in the same way as Word. Operations may assume
-- and must ensure that it holds only values from its logical range.

data Word8 = W8# Word# deriving (Eq, Ord)

instance CCallable Word8
instance CReturnable Word8

instance Show Word8 where
    showsPrec p x = showsPrec p (fromIntegral x :: Int)

instance Num Word8 where
    (W8# x#) + (W8# y#)    = W8# (wordToWord8# (x# `plusWord#` y#))
    (W8# x#) - (W8# y#)    = W8# (wordToWord8# (x# `minusWord#` y#))
    (W8# x#) * (W8# y#)    = W8# (wordToWord8# (x# `timesWord#` y#))
    negate (W8# x#)        = W8# (wordToWord8# (int2Word# (negateInt# (word2Int# x#))))
    abs x                  = x
    signum 0               = 0
    signum _               = 1
    fromInteger (S# i#)    = W8# (wordToWord8# (int2Word# i#))
    fromInteger (J# s# d#) = W8# (wordToWord8# (integer2Word# s# d#))

instance Real Word8 where
    toRational x = toInteger x % 1

instance Enum Word8 where
    succ x
        | x /= maxBound = x + 1
        | otherwise     = succError "Word8"
    pred x
        | x /= minBound = x - 1
        | otherwise     = predError "Word8"
    toEnum i@(I# i#)
        | i >= 0 && i <= fromIntegral (maxBound::Word8)
                        = W8# (int2Word# i#)
        | otherwise     = toEnumError "Word8" i (minBound::Word8, maxBound::Word8)
    fromEnum (W8# x#)   = I# (word2Int# x#)
    enumFrom            = boundedEnumFrom
    enumFromThen        = boundedEnumFromThen

instance Integral Word8 where
    quot    x@(W8# x#) y@(W8# y#)
        | y /= 0                  = W8# (x# `quotWord#` y#)
        | otherwise               = divZeroError "quot{Word8}" x
    rem     x@(W8# x#) y@(W8# y#)
        | y /= 0                  = W8# (x# `remWord#` y#)
        | otherwise               = divZeroError "rem{Word8}" x
    div     x@(W8# x#) y@(W8# y#)
        | y /= 0                  = W8# (x# `quotWord#` y#)
        | otherwise               = divZeroError "div{Word8}" x
    mod     x@(W8# x#) y@(W8# y#)
        | y /= 0                  = W8# (x# `remWord#` y#)
        | otherwise               = divZeroError "mod{Word8}" x
    quotRem x@(W8# x#) y@(W8# y#)
        | y /= 0                  = (W8# (x# `quotWord#` y#), W8# (x# `remWord#` y#))
        | otherwise               = divZeroError "quotRem{Word8}" x
    divMod  x@(W8# x#) y@(W8# y#)
        | y /= 0                  = (W8# (x# `quotWord#` y#), W8# (x# `remWord#` y#))
        | otherwise               = divZeroError "quotRem{Word8}" x
    toInteger (W8# x#)            = S# (word2Int# x#)

instance Bounded Word8 where
    minBound = 0
    maxBound = 0xFF

instance Ix Word8 where
    range (m,n)       = [m..n]
    index b@(m,_) i
        | inRange b i = fromIntegral (i - m)
        | otherwise   = indexError b i "Word8"
    inRange (m,n) i   = m <= i && i <= n

instance Read Word8 where
    readsPrec p s = [(fromIntegral (x::Int), r) | (x, r) <- readsPrec p s]

instance Bits Word8 where
    (W8# x#) .&.   (W8# y#)   = W8# (x# `and#` y#)
    (W8# x#) .|.   (W8# y#)   = W8# (x# `or#`  y#)
    (W8# x#) `xor` (W8# y#)   = W8# (x# `xor#` y#)
    complement (W8# x#)       = W8# (x# `xor#` mb#) where W8# mb# = maxBound
    (W8# x#) `shift` (I# i#)
        | i# >=# 0#           = W8# (wordToWord8# (x# `shiftL#` i#))
        | otherwise           = W8# (x# `shiftRL#` negateInt# i#)
    (W8# x#) `rotate` (I# i#) = W8# (wordToWord8# ((x# `shiftL#` i'#) `or#`
                                                   (x# `shiftRL#` (8# -# i'#))))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 7#)
    bitSize  _                = 8
    isSigned _                = False

{-# RULES
"fromIntegral/a->Word8" fromIntegral = \x -> case fromIntegral x of W# x# -> W8# (wordToWord8# x#)
"fromIntegral/Word8->a" fromIntegral = \(W8# x#) -> fromIntegral (W# x#)
    #-}

------------------------------------------------------------------------
-- type Word16
------------------------------------------------------------------------

-- Word16 is represented in the same way as Word. Operations may assume
-- and must ensure that it holds only values from its logical range.

data Word16 = W16# Word# deriving (Eq, Ord)

instance CCallable Word16
instance CReturnable Word16

instance Show Word16 where
    showsPrec p x = showsPrec p (fromIntegral x :: Int)

instance Num Word16 where
    (W16# x#) + (W16# y#)  = W16# (wordToWord16# (x# `plusWord#` y#))
    (W16# x#) - (W16# y#)  = W16# (wordToWord16# (x# `minusWord#` y#))
    (W16# x#) * (W16# y#)  = W16# (wordToWord16# (x# `timesWord#` y#))
    negate (W16# x#)       = W16# (wordToWord16# (int2Word# (negateInt# (word2Int# x#))))
    abs x                  = x
    signum 0               = 0
    signum _               = 1
    fromInteger (S# i#)    = W16# (wordToWord16# (int2Word# i#))
    fromInteger (J# s# d#) = W16# (wordToWord16# (integer2Word# s# d#))

instance Real Word16 where
    toRational x = toInteger x % 1

instance Enum Word16 where
    succ x
        | x /= maxBound = x + 1
        | otherwise     = succError "Word16"
    pred x
        | x /= minBound = x - 1
        | otherwise     = predError "Word16"
    toEnum i@(I# i#)
        | i >= 0 && i <= fromIntegral (maxBound::Word16)
                        = W16# (int2Word# i#)
        | otherwise     = toEnumError "Word16" i (minBound::Word16, maxBound::Word16)
    fromEnum (W16# x#)  = I# (word2Int# x#)
    enumFrom            = boundedEnumFrom
    enumFromThen        = boundedEnumFromThen

instance Integral Word16 where
    quot    x@(W16# x#) y@(W16# y#)
        | y /= 0                    = W16# (x# `quotWord#` y#)
        | otherwise                 = divZeroError "quot{Word16}" x
    rem     x@(W16# x#) y@(W16# y#)
        | y /= 0                    = W16# (x# `remWord#` y#)
        | otherwise                 = divZeroError "rem{Word16}" x
    div     x@(W16# x#) y@(W16# y#)
        | y /= 0                    = W16# (x# `quotWord#` y#)
        | otherwise                 = divZeroError "div{Word16}" x
    mod     x@(W16# x#) y@(W16# y#)
        | y /= 0                    = W16# (x# `remWord#` y#)
        | otherwise                 = divZeroError "mod{Word16}" x
    quotRem x@(W16# x#) y@(W16# y#)
        | y /= 0                    = (W16# (x# `quotWord#` y#), W16# (x# `remWord#` y#))
        | otherwise                 = divZeroError "quotRem{Word16}" x
    divMod  x@(W16# x#) y@(W16# y#)
        | y /= 0                    = (W16# (x# `quotWord#` y#), W16# (x# `remWord#` y#))
        | otherwise                 = divZeroError "quotRem{Word16}" x
    toInteger (W16# x#)             = S# (word2Int# x#)

instance Bounded Word16 where
    minBound = 0
    maxBound = 0xFFFF

instance Ix Word16 where
    range (m,n)       = [m..n]
    index b@(m,_) i
        | inRange b i = fromIntegral (i - m)
        | otherwise   = indexError b i "Word16"
    inRange (m,n) i   = m <= i && i <= n

instance Read Word16 where
    readsPrec p s = [(fromIntegral (x::Int), r) | (x, r) <- readsPrec p s]

instance Bits Word16 where
    (W16# x#) .&.   (W16# y#)  = W16# (x# `and#` y#)
    (W16# x#) .|.   (W16# y#)  = W16# (x# `or#`  y#)
    (W16# x#) `xor` (W16# y#)  = W16# (x# `xor#` y#)
    complement (W16# x#)       = W16# (x# `xor#` mb#) where W16# mb# = maxBound
    (W16# x#) `shift` (I# i#)
        | i# >=# 0#            = W16# (wordToWord16# (x# `shiftL#` i#))
        | otherwise            = W16# (x# `shiftRL#` negateInt# i#)
    (W16# x#) `rotate` (I# i#) = W16# (wordToWord16# ((x# `shiftL#` i'#) `or#`
                                                      (x# `shiftRL#` (16# -# i'#))))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 15#)
    bitSize  _                = 16
    isSigned _                = False

{-# RULES
"fromIntegral/a->Word16" fromIntegral = \x -> case fromIntegral x of W# x# -> W16# (wordToWord16# x#)
"fromIntegral/Word16->a" fromIntegral = \(W16# x#) -> fromIntegral (W# x#)
    #-}

------------------------------------------------------------------------
-- type Word32
------------------------------------------------------------------------

-- Word32 is represented in the same way as Word.
#if WORD_SIZE_IN_BYTES == 8
-- Operations may assume and must ensure that it holds only values
-- from its logical range.
#endif

data Word32 = W32# Word# deriving (Eq, Ord)

instance CCallable Word32
instance CReturnable Word32

instance Show Word32 where
#if WORD_SIZE_IN_BYTES == 4
    showsPrec p x = showsPrec p (toInteger x)
#else
    showsPrec p x = showsPrec p (fromIntegral x :: Int)
#endif

instance Num Word32 where
    (W32# x#) + (W32# y#)  = W32# (wordToWord32# (x# `plusWord#` y#))
    (W32# x#) - (W32# y#)  = W32# (wordToWord32# (x# `minusWord#` y#))
    (W32# x#) * (W32# y#)  = W32# (wordToWord32# (x# `timesWord#` y#))
    negate (W32# x#)       = W32# (wordToWord32# (int2Word# (negateInt# (word2Int# x#))))
    abs x                  = x
    signum 0               = 0
    signum _               = 1
    fromInteger (S# i#)    = W32# (wordToWord32# (int2Word# i#))
    fromInteger (J# s# d#) = W32# (wordToWord32# (integer2Word# s# d#))

instance Real Word32 where
    toRational x = toInteger x % 1

instance Enum Word32 where
    succ x
        | x /= maxBound = x + 1
        | otherwise     = succError "Word32"
    pred x
        | x /= minBound = x - 1
        | otherwise     = predError "Word32"
    toEnum i@(I# i#)
        | i >= 0
#if WORD_SIZE_IN_BYTES == 8
          && i <= fromIntegral (maxBound::Word32)
#endif
                        = W32# (int2Word# i#)
        | otherwise     = toEnumError "Word32" i (minBound::Word32, maxBound::Word32)
#if WORD_SIZE_IN_BYTES == 4
    fromEnum x@(W32# x#)
        | x <= fromIntegral (maxBound::Int)
                        = I# (word2Int# x#)
        | otherwise     = fromEnumError "Word32" x
    enumFrom            = integralEnumFrom
    enumFromThen        = integralEnumFromThen
    enumFromTo          = integralEnumFromTo
    enumFromThenTo      = integralEnumFromThenTo
#else
    fromEnum (W32# x#)  = I# (word2Int# x#)
    enumFrom            = boundedEnumFrom
    enumFromThen        = boundedEnumFromThen
#endif

instance Integral Word32 where
    quot    x@(W32# x#) y@(W32# y#)
        | y /= 0                    = W32# (x# `quotWord#` y#)
        | otherwise                 = divZeroError "quot{Word32}" x
    rem     x@(W32# x#) y@(W32# y#)
        | y /= 0                    = W32# (x# `remWord#` y#)
        | otherwise                 = divZeroError "rem{Word32}" x
    div     x@(W32# x#) y@(W32# y#)
        | y /= 0                    = W32# (x# `quotWord#` y#)
        | otherwise                 = divZeroError "div{Word32}" x
    mod     x@(W32# x#) y@(W32# y#)
        | y /= 0                    = W32# (x# `remWord#` y#)
        | otherwise                 = divZeroError "mod{Word32}" x
    quotRem x@(W32# x#) y@(W32# y#)
        | y /= 0                    = (W32# (x# `quotWord#` y#), W32# (x# `remWord#` y#))
        | otherwise                 = divZeroError "quotRem{Word32}" x
    divMod  x@(W32# x#) y@(W32# y#)
        | y /= 0                    = (W32# (x# `quotWord#` y#), W32# (x# `remWord#` y#))
        | otherwise                 = divZeroError "quotRem{Word32}" x
    toInteger (W32# x#)
#if WORD_SIZE_IN_BYTES == 4
        | i# >=# 0#                 = S# i#
        | otherwise                 = case word2Integer# x# of (# s, d #) -> J# s d
        where
        i# = word2Int# x#
#else
                                    = S# (word2Int# x#)
#endif

instance Bounded Word32 where
    minBound = 0
    maxBound = 0xFFFFFFFF

instance Ix Word32 where
    range (m,n)       = [m..n]
    index b@(m,_) i
        | inRange b i = fromIntegral (i - m)
        | otherwise   = indexError b i "Word32"
    inRange (m,n) i   = m <= i && i <= n

instance Read Word32 where
#if WORD_SIZE_IN_BYTES == 4
    readsPrec p s = [(fromInteger x, r) | (x, r) <- readsPrec p s]
#else
    readsPrec p s = [(fromIntegral (x::Int), r) | (x, r) <- readsPrec p s]
#endif

instance Bits Word32 where
    (W32# x#) .&.   (W32# y#)  = W32# (x# `and#` y#)
    (W32# x#) .|.   (W32# y#)  = W32# (x# `or#`  y#)
    (W32# x#) `xor` (W32# y#)  = W32# (x# `xor#` y#)
    complement (W32# x#)       = W32# (x# `xor#` mb#) where W32# mb# = maxBound
    (W32# x#) `shift` (I# i#)
        | i# >=# 0#            = W32# (wordToWord32# (x# `shiftL#` i#))
        | otherwise            = W32# (x# `shiftRL#` negateInt# i#)
    (W32# x#) `rotate` (I# i#) = W32# (wordToWord32# ((x# `shiftL#` i'#) `or#`
                                                      (x# `shiftRL#` (32# -# i'#))))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 31#)
    bitSize  _                = 32
    isSigned _                = False

{-# RULES
"fromIntegral/a->Word32" fromIntegral = \x -> case fromIntegral x of W# x# -> W32# (wordToWord32# x#)
"fromIntegral/Word32->a" fromIntegral = \(W32# x#) -> fromIntegral (W# x#)
    #-}

------------------------------------------------------------------------
-- type Word64
------------------------------------------------------------------------

#if WORD_SIZE_IN_BYTES == 4

data Word64 = W64# Word64#

instance Eq Word64 where
    (W64# x#) == (W64# y#) = x# `eqWord64#` y#
    (W64# x#) /= (W64# y#) = x# `neWord64#` y#

instance Ord Word64 where
    (W64# x#) <  (W64# y#) = x# `ltWord64#` y#
    (W64# x#) <= (W64# y#) = x# `leWord64#` y#
    (W64# x#) >  (W64# y#) = x# `gtWord64#` y#
    (W64# x#) >= (W64# y#) = x# `geWord64#` y#

instance Num Word64 where
    (W64# x#) + (W64# y#)  = W64# (int64ToWord64# (word64ToInt64# x# `plusInt64#` word64ToInt64# y#))
    (W64# x#) - (W64# y#)  = W64# (int64ToWord64# (word64ToInt64# x# `minusInt64#` word64ToInt64# y#))
    (W64# x#) * (W64# y#)  = W64# (int64ToWord64# (word64ToInt64# x# `timesInt64#` word64ToInt64# y#))
    negate (W64# x#)       = W64# (int64ToWord64# (negateInt64# (word64ToInt64# x#)))
    abs x                  = x
    signum 0               = 0
    signum _               = 1
    fromInteger (S# i#)    = W64# (int64ToWord64# (intToInt64# i#))
    fromInteger (J# s# d#) = W64# (integerToWord64# s# d#)

instance Enum Word64 where
    succ x
        | x /= maxBound = x + 1
        | otherwise     = succError "Word64"
    pred x
        | x /= minBound = x - 1
        | otherwise     = predError "Word64"
    toEnum i@(I# i#)
        | i >= 0        = W64# (wordToWord64# (int2Word# i#))
        | otherwise     = toEnumError "Word64" i (minBound::Word64, maxBound::Word64)
    fromEnum x@(W64# x#)
        | x <= fromIntegral (maxBound::Int)
                        = I# (word2Int# (word64ToWord# x#))
        | otherwise     = fromEnumError "Word64" x
    enumFrom            = integralEnumFrom
    enumFromThen        = integralEnumFromThen
    enumFromTo          = integralEnumFromTo
    enumFromThenTo      = integralEnumFromThenTo

instance Integral Word64 where
    quot    x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `quotWord64#` y#)
        | otherwise                 = divZeroError "quot{Word64}" x
    rem     x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `remWord64#` y#)
        | otherwise                 = divZeroError "rem{Word64}" x
    div     x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `quotWord64#` y#)
        | otherwise                 = divZeroError "div{Word64}" x
    mod     x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `remWord64#` y#)
        | otherwise                 = divZeroError "mod{Word64}" x
    quotRem x@(W64# x#) y@(W64# y#)
        | y /= 0                    = (W64# (x# `quotWord64#` y#), W64# (x# `remWord64#` y#))
        | otherwise                 = divZeroError "quotRem{Word64}" x
    divMod  x@(W64# x#) y@(W64# y#)
        | y /= 0                    = (W64# (x# `quotWord64#` y#), W64# (x# `remWord64#` y#))
        | otherwise                 = divZeroError "quotRem{Word64}" x
    toInteger x@(W64# x#)
        | x <= 0x7FFFFFFF           = S# (word2Int# (word64ToWord# x#))
        | otherwise                 = case word64ToInteger# x# of (# s, d #) -> J# s d

instance Bits Word64 where
    (W64# x#) .&.   (W64# y#)  = W64# (x# `and64#` y#)
    (W64# x#) .|.   (W64# y#)  = W64# (x# `or64#`  y#)
    (W64# x#) `xor` (W64# y#)  = W64# (x# `xor64#` y#)
    complement (W64# x#)       = W64# (not64# x#)
    (W64# x#) `shift` (I# i#)
        | i# >=# 0#            = W64# (x# `shiftL64#` i#)
        | otherwise            = W64# (x# `shiftRL64#` negateInt# i#)
    (W64# x#) `rotate` (I# i#) = W64# ((x# `shiftL64#` i'#) `or64#`
                                       (x# `shiftRL64#` (64# -# i'#)))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 63#)
    bitSize  _                = 64
    isSigned _                = False

foreign import "stg_eqWord64"      unsafe eqWord64#      :: Word64# -> Word64# -> Bool
foreign import "stg_neWord64"      unsafe neWord64#      :: Word64# -> Word64# -> Bool
foreign import "stg_ltWord64"      unsafe ltWord64#      :: Word64# -> Word64# -> Bool
foreign import "stg_leWord64"      unsafe leWord64#      :: Word64# -> Word64# -> Bool
foreign import "stg_gtWord64"      unsafe gtWord64#      :: Word64# -> Word64# -> Bool
foreign import "stg_geWord64"      unsafe geWord64#      :: Word64# -> Word64# -> Bool
foreign import "stg_int64ToWord64" unsafe int64ToWord64# :: Int64# -> Word64#
foreign import "stg_word64ToInt64" unsafe word64ToInt64# :: Word64# -> Int64#
foreign import "stg_plusInt64"     unsafe plusInt64#     :: Int64# -> Int64# -> Int64#
foreign import "stg_minusInt64"    unsafe minusInt64#    :: Int64# -> Int64# -> Int64#
foreign import "stg_timesInt64"    unsafe timesInt64#    :: Int64# -> Int64# -> Int64#
foreign import "stg_negateInt64"   unsafe negateInt64#   :: Int64# -> Int64#
foreign import "stg_intToInt64"    unsafe intToInt64#    :: Int# -> Int64#
foreign import "stg_wordToWord64"  unsafe wordToWord64#  :: Word# -> Word64#
foreign import "stg_word64ToWord"  unsafe word64ToWord#  :: Word64# -> Word#
foreign import "stg_quotWord64"    unsafe quotWord64#    :: Word64# -> Word64# -> Word64#
foreign import "stg_remWord64"     unsafe remWord64#     :: Word64# -> Word64# -> Word64#
foreign import "stg_and64"         unsafe and64#         :: Word64# -> Word64# -> Word64#
foreign import "stg_or64"          unsafe or64#          :: Word64# -> Word64# -> Word64#
foreign import "stg_xor64"         unsafe xor64#         :: Word64# -> Word64# -> Word64#
foreign import "stg_not64"         unsafe not64#         :: Word64# -> Word64#
foreign import "stg_shiftL64"      unsafe shiftL64#      :: Word64# -> Int# -> Word64#
foreign import "stg_shiftRL64"     unsafe shiftRL64#     :: Word64# -> Int# -> Word64#

{-# RULES
"fromIntegral/Int->Word64"    fromIntegral = \(I#   x#) -> W64# (int64ToWord64# (intToInt64# x#))
"fromIntegral/Word->Word64"   fromIntegral = \(W#   x#) -> W64# (wordToWord64# x#)
"fromIntegral/Word64->Int"    fromIntegral = \(W64# x#) -> I#   (word2Int# (word64ToWord# x#))
"fromIntegral/Word64->Word"   fromIntegral = \(W64# x#) -> W#   (word64ToWord# x#)
"fromIntegral/Word64->Word64" fromIntegral = id :: Word64 -> Word64
    #-}

#else

data Word32 = W64# Word# deriving (Eq, Ord)

instance Num Word64 where
    (W64# x#) + (W64# y#)  = W64# (x# `plusWord#` y#)
    (W64# x#) - (W64# y#)  = W64# (x# `minusWord#` y#)
    (W64# x#) * (W64# y#)  = W64# (x# `timesWord#` y#)
    negate (W64# x#)       = W64# (int2Word# (negateInt# (word2Int# x#)))
    abs x                  = x
    signum 0               = 0
    signum _               = 1
    fromInteger (S# i#)    = W64# (int2Word# i#)
    fromInteger (J# s# d#) = W64# (integer2Word# s# d#)

instance Enum Word64 where
    succ x
        | x /= maxBound = x + 1
        | otherwise     = succError "Word64"
    pred x
        | x /= minBound = x - 1
        | otherwise     = predError "Word64"
    toEnum i@(I# i#)
        | i >= 0        = W64# (int2Word# i#)
        | otherwise     = toEnumError "Word64" i (minBound::Word64, maxBound::Word64)
    fromEnum x@(W64# x#)
        | x <= fromIntegral (maxBound::Int)
                        = I# (word2Int# x#)
        | otherwise     = fromEnumError "Word64" x
    enumFrom            = integralEnumFrom
    enumFromThen        = integralEnumFromThen
    enumFromTo          = integralEnumFromTo
    enumFromThenTo      = integralEnumFromThenTo

instance Integral Word64 where
    quot    x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `quotWord#` y#)
        | otherwise                 = divZeroError "quot{Word64}" x
    rem     x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `remWord#` y#)
        | otherwise                 = divZeroError "rem{Word64}" x
    div     x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `quotWord#` y#)
        | otherwise                 = divZeroError "div{Word64}" x
    mod     x@(W64# x#) y@(W64# y#)
        | y /= 0                    = W64# (x# `remWord#` y#)
        | otherwise                 = divZeroError "mod{Word64}" x
    quotRem x@(W64# x#) y@(W64# y#)
        | y /= 0                    = (W64# (x# `quotWord#` y#), W64# (x# `remWord#` y#))
        | otherwise                 = divZeroError "quotRem{Word64}" x
    divMod  x@(W64# x#) y@(W64# y#)
        | y /= 0                    = (W64# (x# `quotWord#` y#), W64# (x# `remWord#` y#))
        | otherwise                 = divZeroError "quotRem{Word64}" x
    toInteger (W64# x#)
        | i# >=# 0#                 = S# i#
        | otherwise                 = case word2Integer# x# of (# s, d #) -> J# s d
        where
        i# = word2Int# x#

instance Bits Word64 where
    (W64# x#) .&.   (W64# y#)  = W64# (x# `and#` y#)
    (W64# x#) .|.   (W64# y#)  = W64# (x# `or#`  y#)
    (W64# x#) `xor` (W64# y#)  = W64# (x# `xor#` y#)
    complement (W64# x#)       = W64# (x# `xor#` mb#) where W64# mb# = maxBound
    (W64# x#) `shift` (I# i#)
        | i# >=# 0#            = W64# (x# `shiftL#` i#)
        | otherwise            = W64# (x# `shiftRL#` negateInt# i#)
    (W64# x#) `rotate` (I# i#) = W64# ((x# `shiftL#` i'#) `or#`
                                       (x# `shiftRL#` (64# -# i'#)))
        where
        i'# = word2Int# (int2Word# i# `and#` int2Word# 63#)
    bitSize  _                = 64
    isSigned _                = False

{-# RULES
"fromIntegral/a->Word64" fromIntegral = \x -> case fromIntegral x of W# x# -> W64# x#
"fromIntegral/Word64->a" fromIntegral = \(W64# x#) -> fromIntegral (W# x#)
    #-}

#endif

instance CCallable Word64
instance CReturnable Word64

instance Show Word64 where
    showsPrec p x = showsPrec p (toInteger x)

instance Real Word64 where
    toRational x = toInteger x % 1

instance Bounded Word64 where
    minBound = 0
    maxBound = 0xFFFFFFFFFFFFFFFF

instance Ix Word64 where
    range (m,n)       = [m..n]
    index b@(m,_) i
        | inRange b i = fromIntegral (i - m)
        | otherwise   = indexError b i "Word64"
    inRange (m,n) i   = m <= i && i <= n

instance Read Word64 where
    readsPrec p s = [(fromInteger x, r) | (x, r) <- readsPrec p s]
\end{code}
