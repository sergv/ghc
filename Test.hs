-- |
-- Module:     Test
-- Copyright:  (c) Sergey Vinokurov 2024
-- License:    Apache-2.0 (see LICENSE)
-- Maintainer: serg.foo@gmail.com

{-# LANGUAGE MagicHash #-}

-- {-# OPTIONS_GHC -O2 -ddump-simpl -dsuppress-uniques -dsuppress-idinfo -dsuppress-module-prefixes -dsuppress-type-applications -dsuppress-coercions -dppr-cols200 -dsuppress-type-signatures -ddump-to-file #-}

-- {-# OPTIONS_GHC -ddump-stg -ddump-cmm -ddump-to-file #-}

{-# OPTIONS_GHC -ddump-stg-final #-}

module Test where

import qualified Debug.Trace

import Data.Bits
import Data.Int
import Data.Word
import GHC.Exts
import GHC.Word
import Text.Printf

toHex :: Word64 -> String
toHex x = printf "0x%016x %d %d" x x (fromIntegral x :: Int32)

subtractThenAnd :: Word64 -> Word64
subtractThenAnd !(W64# x) =
  W64# ((x `subWord64#` ones) `and64#` not64# x)
  where
    !(W64# ones) = 0x0101010101010101

{-# NOINLINE subtractThenAndNoinline #-}
subtractThenAndNoinline :: Word64 -> Word64
subtractThenAndNoinline !(W64# x) =
  W64# ((x `subWord64#` ones) `and64#` not64# x)
  where
    !(W64# ones) = 0x0101010101010101

-- -- {-# NOINLINE hasZeroByte #-}
-- hasZeroByte :: Word64 -> Bool
-- hasZeroByte !(W64# x) =
--   -- isTrue# (wordToWord64# 0## `ltWord64#` (((x `subWord64#` wordToWord64# 0x0101010101010101##) `and64#` not64# x `and64#` wordToWord64# 0x8080808080808080##)))
--   -- Debug.Trace.trace ("((x `subWord64#` ones) `and64#` not64# x = " ++ printf "0x%x" (W64# (((x `subWord64#` ones) `and64#` not64# x)))) $
--   isTrue# (wordToWord64# 0## `ltWord64#` (((x `subWord64#` ones) `and64#` not64# x `and64#` eights)))
--   where
--     !(W64# eights) = 0x8080808080808080
--     !(W64# ones)   = 0x0101010101010101

-- {-# NOINLINE hasZeroByte #-}
-- hasZeroByte :: Word64 -> Bool
-- hasZeroByte !(W64# x) =
--   -- isTrue# (wordToWord64# 0## `ltWord64#` (((x `subWord64#` wordToWord64# 0x0101010101010101##) `and64#` not64# x `and64#` wordToWord64# 0x8080808080808080##)))
--   Debug.Trace.trace ("hasZeroByte: x                                                           = " ++ printf "0x%x" (W64# x)) $
--   Debug.Trace.trace ("hasZeroByte: (x `subWord64#` ones)                                       = " ++ printf "0x%x" (W64# ((x `subWord64#` ones)))) $
--   Debug.Trace.trace ("hasZeroByte: not64# x                                                    = " ++ printf "0x%x" (W64# (not64# x))) $
--   Debug.Trace.trace ("hasZeroByte: ((x `subWord64#` ones) `and64#` not64# x)                   = " ++ printf "0x%x" (W64# ((x `subWord64#` ones) `and64#` not64# x))) $
--   Debug.Trace.trace ("hasZeroByte: ((x `subWord64#` ones) `and64#` (not64# x `and64#` eights)) = " ++ printf "0x%x" (W64# ((x `subWord64#` ones) `and64#` (not64# x `and64#` eights)))) $
--   -- Debug.Trace.trace ("((x `subWord64#` ones) `and64#` not64# x = " ++ printf "0x%x" (W64# (((x `subWord64#` ones) `and64#` not64# x)))) $
--   isTrue# (wordToWord64# 0## `ltWord64#` (((x `subWord64#` ones) `and64#` not64# x `and64#` eights)))
--   where
--     !(W64# eights) = 0x8080808080808080
--     !(W64# ones)   = 0x0101010101010101



main :: IO ()
main = do
  -- let x = 0x3333333333333333
  --     y = 0x1111111111111111
  --     z = x - y
  --     w = x .&. y
  -- putStrLn $ "x = " ++ toHex x
  -- putStrLn $ "y = " ++ toHex y
  -- putStrLn $ "z = " ++ toHex z
  -- putStrLn $ "w = " ++ toHex w

  -- let x, r :: Word64
  --     x = 0x6666000909202929
  --     r = ((x - (0x0101010101010101 :: Word64)) .&. complement x)
  -- putStrLn $ "x = " ++ toHex x
  -- putStrLn $ "r = " ++ toHex r

  let x :: Word64
      x = 0x6666000909202929

  putStrLn $ "ones        = " ++ toHex 0x0101010101010101
  putStrLn $ "negate ones = " ++ toHex (negate 0x0101010101010101)
  putStrLn $ "-16843009   = " ++ toHex (fromIntegral (-16843009 :: Int64))
  putStrLn $ "x           = " ++ toHex x
  putStrLn $ "default     = " ++ toHex (subtractThenAnd x)
  putStrLn $ "noinline    = " ++ toHex (subtractThenAndNoinline x)
  -- putStrLn $ "r = " ++ show (hasZeroByte x)

  pure ()

-- x = 0x6666000909202929, complement x = 0x9999fff6f6dfd6d6, x - (0x0101010101010101 :: Word64) = 0x6564ff08081f2828
