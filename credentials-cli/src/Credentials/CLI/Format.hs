{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TupleSections        #-}

{-# OPTIONS_GHC -fno-warn-type-defaults #-}

-- |
-- Module      : Credentials.CLI.Format
-- Copyright   : (c) 2015 Brendan Hay
-- License     : Mozilla Public License, v. 2.0.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : provisional
-- Portability : non-portable (GHC extensions)
--
module Credentials.CLI.Format where

import           Credentials
import           Credentials.CLI.Types
import           Data.Aeson               (ToJSON (..), object, (.=))
import           Data.List                (foldl', intersperse)
import           Data.List.NonEmpty       (NonEmpty (..))
import           Data.Monoid
import           Network.AWS.Data
import           Options.Applicative.Help hiding (string)

data Status
    = Deleted
    | Truncated

instance ToLog Status where
    build = build . toText

instance ToText Status where
    toText = \case
        Deleted   -> "deleted"
        Truncated -> "truncated"

data Emit = Emit { store' :: Store, result :: Result }

instance ToJSON Emit where
    toJSON (Emit s r) = object [toText s .= r]

instance Pretty Emit where
    pretty (Emit s r) = pretty s <> char ':' .$. indent 2 (pretty r)

data Result
    = SetupR    Setup
    | CleanupR
    | PutR      Name Revision
    | GetR      Name Value Revision
    | DeleteR   Name Revision
    | TruncateR Name
    | ListR     Revisions

instance ToLog Result where
    build = \case
        SetupR        s -> build s
        CleanupR        -> build Deleted
        PutR      _ r   -> build r
        GetR      _ v _ -> build (toBS v)
        DeleteR   {}    -> build Deleted
        TruncateR {}    -> build Truncated
        ListR        rs -> foldMap f rs
          where
            f (n, v :| vs) =
                build n % "," % mconcat (intersperse "," $ map build (v:vs)) % "\n"

instance ToJSON Result where
    toJSON = \case
        SetupR        s -> object ["status" =~ s]
        CleanupR        -> object ["status" =~ Deleted]
        PutR      n   r -> object ["name"   =~ n, "revision" =~ r]
        GetR      n v r -> object ["name"   =~ n, "revision" =~ r, "secret" =~ toBS v]
        DeleteR   n   r -> object ["name"   =~ n, "revision" =~ r, "status" =~ Deleted]
        TruncateR n     -> object ["name"   =~ n, "status"   =~ Truncated]
        ListR        rs -> object (map go rs)
      where
        k =~ v = k .= toText v

        go (n, v :| vs) = toText n .= map toText (v:vs)

instance Pretty Result where
    pretty = \case
        SetupR        s -> stat s
        CleanupR        -> stat Deleted
        PutR      n   r -> name n .$. rev r
        GetR      n v r -> name n .$. rev r .$. val v
        DeleteR   n r   -> name n .$. rev r .$. stat Deleted
        TruncateR n     -> name n .$. stat Truncated
        ListR        rs -> go rs
      where
        doc :: ToText a => a -> Doc
        doc = text . string

        name n = "name:"     <+> doc n
        rev  r = "revision:" <+> doc r
        stat s = "status:"   <+> doc s
        val  v = "secret:"   <+> doc (toBS v)

        go []     = mempty
        go (r:rs) = foldl' (.$.) (f r) (map f rs)
          where
            f (n, v :| vs) = doc n <> ":" .$.
                indent 2 (extractChunk (revs v vs))

            revs v vs = tabulate $
                (item v, "# latest") : map ((,mempty) . item) vs

            item x = "-" <+> doc x
