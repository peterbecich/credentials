{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Credentials.CLI.Options
-- Copyright   : (c) 2015-2016 Brendan Hay
-- License     : Mozilla Public License, v. 2.0.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : provisional
-- Portability : non-portable (GHC extensions)
--
module Credentials.CLI.Options where

import Credentials.CLI.Types

import Data.Bifunctor
import Data.List      (foldl')
import Data.Maybe     (isJust)

import Network.AWS.Data
import Network.AWS.Data.Text

import Options.Applicative      hiding (optional)
import Options.Applicative.Help hiding (string)

import qualified Data.Text           as Text
import qualified Options.Applicative as Opt

data Fact
    = Required
    | Optional
    | Default

-- | Setup an option with formatted help text.
describe :: Text    -- ^ The options' description.
         -> Maybe Doc -- ^ The help body (title/footer in tabular).
         -> Fact
         -> Mod OptionFields a
describe title body r = helpDoc . Just $ wrap title <> doc <> line
  where
    doc | Just b <- body = pad (maybe b (b .$.) foot)
        | otherwise      = maybe mempty pad foot

    foot = case r of
        Required -> Just ("This is" <+> bold "required.")
        Optional -> Just ("This is" <+> bold "optional.")
        Default  -> Nothing

    pad = mappend line . indent 2

-- | Setup a tabular list of possible values for an option,
-- a default value, and an auto-completer.
completes :: ToText a
          => Text          -- ^ The options' description.
          -> Text          -- ^ A title for the values.
          -> [(a, String)] -- ^ Possible values and their documentation.
          -> Maybe a       -- ^ A default value.
          -> Maybe Text    -- ^ Footer contents.
          -> Mod OptionFields a
completes title note xs x foot = doc <> completeWith (map fst ys)
  where
    doc = defaults title note ys x foot
    ys  = map (first string) xs

-- | Construct a tabular representation displaying the default values,
-- without using ToText for the tabular values.
defaults :: ToText a
         => Text
         -> Text
         -> [(String, String)]
         -> Maybe a
         -> Maybe Text
         -> Mod OptionFields a
defaults title note xs x foot =
    describe title (Just doc) Default <> maybe mempty value x
  where
    doc   = maybe table (table .$.) (wrap <$> foot)
    table = wrap note
        .$. indent 2 rows
        $$$ ( case x of
               Nothing -> mempty
               Just y  -> "Defaults to " <> bold (text (string y)) <> "."
            )

    ($$$) | isJust  x = (.$.)
          | otherwise = mappend

    len = maximum (map (length . fst) xs)

    rows | [r]  <- xs = f r
         | r:rs <- xs = foldl' (.$.) (f r) (map f rs)
         | otherwise  = mempty
      where
        f (k, v) = "-" <+> bold (text k) <+> indent (len - length k) ts
          where
            ts | null v    = mempty
               | otherwise = tupled [text v]

require :: (Fact -> a) -> a
require f = f Required

optional :: Alternative f => (Fact -> f a) -> f (Maybe a)
optional f = Opt.optional (f Optional)

textOption :: FromText a => Mod OptionFields a -> Parser a
textOption = option (eitherReader (fromText . Text.pack))

wrap :: Text -> Doc
wrap = extractChunk . paragraph . Text.unpack
