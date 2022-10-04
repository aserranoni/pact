{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      :  Pact.Types.Persistence
-- Copyright   :  (C) 2019 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- 'Codec' pairs 'ToJSON' and 'FromJSON' marshalling.
--
module Pact.Types.Codec
  ( jsIntegerBounds
  , Codec(..)
  , integerCodec
  , decimalCodec
  , timeCodec
  , valueCodec
  , pactISO8601Format
  , highPrecFormat
  , roundtripCodec
  , withThisText
  ) where

import Control.Applicative
import qualified Data.Aeson as A
import qualified Data.Aeson.Encoding as A
import Data.Aeson hiding (Object)
import Data.Aeson.Types (Parser,parse)
import Data.Text (Text,unpack)
import Pact.Time
import Data.Decimal (Decimal,DecimalRaw(..))
import Text.Read (readMaybe)
import Data.Ratio ((%), denominator)



-- | Min, max values that Javascript doesn't mess up.
--
--   http://blog.vjeux.com/2010/javascript/javascript-max_int-number-limits.html
--   "The integer part of the Number type in Javascript is safe in [-2^53 .. 2^53] (253 = 9 007 199 254 740 992).
--    Beyond this there will be precision loss on the least significant numbers."
jsIntegerBounds :: (Integer, Integer)
jsIntegerBounds = (-9007199254740991,9007199254740991)

isSafeInteger :: Integer -> Bool
isSafeInteger i = i >= l && i <= h
  where (l,h) = jsIntegerBounds

-- | JSON codec pair.
data Codec a = Codec {
  encoder :: a -> Encoding,
  decoder :: Value -> Parser a,
  valueEncoder :: a -> Value
  }

-- | Integers encode to an object that uses Number if in reasonable JS bounds or String otherwise.
integerCodec :: Codec Integer
integerCodec = Codec encodeInteger decodeInteger encodeIntegerToValue
  where
    encodeInteger i
      | isSafeInteger i = pairs ( field .= i )
      | otherwise = pairs ( field .= show i )
    {-# INLINE encodeInteger #-}
    encodeIntegerToValue i
      | isSafeInteger i = object [ field .= i ]
      | otherwise = object [ field .= show i ]
    {-# INLINE encodeIntegerToValue #-}
    decodeInteger = withObject "Integer" $ \o -> do
      s <- o .: field
      case s of
        Number n -> return (round n)
        String n -> case readMaybe (unpack n) of
          Just i -> return i
          Nothing -> fail $ "Invalid integer value: " ++ show s
        _ -> fail $ "Invalid integer value: " ++ show s
    {-# INLINE decodeInteger #-}
    field = "int"

-- | Decimals encode to a Scientific, which is encoded as an object + String
-- if mantissa precision exceeds JS.
-- TODO fromRational . toRational may not be the speediest.
decimalCodec :: Codec Decimal
decimalCodec = Codec enc dec encValue
  where
    enc d@(Decimal _places mantissa)
      | isSafeInteger mantissa = A.scientific $ fromRational $ toRational d
      | otherwise = pairs ( field .= show d )
    {-# INLINE enc #-}
    encValue d@(Decimal _places mantissa)
      | isSafeInteger mantissa = Number $ fromRational $ toRational d
      | otherwise = object [ field .= show d ]
    {-# INLINE encValue #-}
    dec (Number n) = return $ fromRational $ toRational n
    dec (A.Object o) = o .: field >>= \s -> case readMaybe (unpack s) of
      Just d -> return d
      Nothing -> fail $ "Invalid decimal value: " ++ show s
    dec v = fail $ "Invalid decimal value: " ++ show v
    {-# INLINE dec #-}
    field = "decimal"

-- | default Pact ISO8601 format
pactISO8601Format :: String
pactISO8601Format = "%Y-%m-%dT%H:%M:%SZ"

-- | high-precision format
highPrecFormat :: String
highPrecFormat = "%Y-%m-%dT%H:%M:%S.%vZ"

-- | Time uses
timeCodec :: Codec UTCTime
timeCodec = Codec enc dec encValue
  where
    enc t
      | 1 == denom t = pairs ( field .= formatTime pactISO8601Format t )
      | otherwise = pairs ( highprec .= formatTime highPrecFormat t )
    {-# INLINE enc #-}
    encValue t
      | 1 == denom t = object [ field .= formatTime pactISO8601Format t ]
      | otherwise = object [ highprec .= formatTime highPrecFormat t ]
    {-# INLINE encValue #-}
    dec = withObject "time" $ \o ->
      (o .: field >>= mkTime pactISO8601Format) <|>
      (o .: highprec >>= mkTime highPrecFormat)
      where
        mkTime :: String -> String -> Parser UTCTime
        mkTime fmt v = case parseTime fmt v of
              Just t -> return t
              Nothing -> fail $ "Invalid time value, expected " ++ fmt
    {-# INLINE dec #-}
    field = "time"
    highprec = "timep"

    denom :: UTCTime -> Integer
    denom = denominator . (% 1000) . fromIntegral . toPosixTimestampMicros

valueCodec :: Codec Value
valueCodec = Codec enc dec encVal
  where
    enc v = pairs (field .= v)
    {-# INLINE enc #-}
    encVal v = object [field .= v]
    {-# INLINE encVal #-}
    dec = withObject "Value" $ \o -> o .: field
    {-# INLINE dec #-}
    field = "_P_val"


roundtripCodec :: Codec t -> t -> Result t
roundtripCodec c t = parse (decoder c) $ valueEncoder c t

withThisText :: String -> Text -> Value -> Parser a -> Parser a
withThisText s t v p = withText s go v
  where
    go tv | tv == t = p
          | otherwise = fail $ s ++ ": Expected " ++ show t
