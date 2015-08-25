{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExtendedDefaultRules       #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -fno-warn-type-defaults #-}

-- |
-- Module      : Main
-- Copyright   : (c) 2015 Brendan Hay
-- License     : Mozilla Public License, v. 2.0.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : provisional
-- Portability : non-portable (GHC extensions)
--
module Main (main) where

import           Control.Exception.Lens
import           Control.Lens                         (view, ( # ), (&), (.~),
                                                       (<&>))
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Credentials                          as Store hiding (context)
import           Credentials.CLI.IO
import           Credentials.CLI.Types
import           Data.ByteString                      (ByteString)
import qualified Data.ByteString                      as BS
import           Data.ByteString.Builder              (Builder)
import qualified Data.ByteString.Builder              as Build
import qualified Data.ByteString.Char8                as BS8
import           Data.Char
import           Data.Conduit                         (($$))
import qualified Data.Conduit.List                    as CL
import           Data.Data
import           Data.HashMap.Strict                  (HashMap)
import           Data.List.NonEmpty                   (NonEmpty (..))
import qualified Data.List.NonEmpty                   as NE
import           Data.Maybe
import qualified Data.Text                            as Text
import qualified Data.Text.IO                         as Text
import           Network.AWS
import           Network.AWS.Data
import           Network.AWS.Data.Text
import           Network.AWS.S3                       (BucketName,
                                                       ObjectVersionId)
import           Numeric.Natural
import           Options.Applicative
import           Options.Applicative.Builder.Internal (HasCompleter)
import           System.Exit
import           System.IO

default (Builder)

main :: IO ()
main = do
    (r, v, m) <- customExecParser settings options

    l <- newLogger v stdout
    e <- newEnv r Discover <&> (envLogger .~ l) . storeEndpoint (current m)

    catches (runApp e (program r m))
        [ handler _CredentialError $ \x -> quit 1 (show x)
        ]

program :: Region -> Mode -> App ()
program r = \case
    Setup s -> do
        says ("Setting up " % s <> " in " % r <> ".")
        x <- Store.setup s
        says $ "Created " % s % " " % x % "."

    Cleanup s f -> do
        says ("This will delete " % s % " from " % r % "!")
        prompt f $ do
            Store.cleanup s
            says ("Deleted " % s % ".")

    List s f -> do
        xs <- list s
        say (Output f xs)

    Put s k c n i -> do
        says ("Put " % n % " to " % s % ".")
        x <- case i of
            Raw  v -> pure v
            Path p -> do
                says ("Reading secret from " % p % "...")
                Value <$> liftIO (BS.readFile p)

        v <- Store.put k c n x s
        says ("Wrote version " % v % " of " % n % ".")

    Get s c n v f -> do
        x <- Store.get c n v s
        say (Output f (n, x))

    Delete s n v f -> do
        says ("This will delete version " % v % " of " % n % " from " % s % " in " % r % "!")
        prompt f $ do
            Store.delete n v s
            says ("Deleted version " % v % " of " % n % ".")

settings :: ParserPrefs
settings = prefs (showHelpOnError <> columns 100)

options :: ParserInfo (Region, LogLevel, Mode)
options = info (helper <*> liftA3 (,,) region level modes) (fullDesc <> header about)
  where
    modes = subparser $ mconcat
        [ mode "setup"
            (Setup <$> store)
            "Setup a new credential store."

        , mode "cleanup"
            (Cleanup <$> store <*> force)
            "Remove the credential store entirely."

        , mode "list"
            (List <$> store <*> format)
            "List credential names and the respective versions\
            \ in the specified store."

        , mode "get"
            (Get <$> store <*> context <*> name <*> optional version <*> format)
            "Fetch and decrypt a specific version of a credential from the store. \
            \[default: latest]"

        , mode "put"
            (Put <$> store <*> key <*> context <*> name <*> input)
            "Write and encrypt a new version of a credential to the store. \
            \You can supply the secret as a string with --secret, or as \
            \a file path to the secret's contents using --path."

        , mode "delete"
            (Delete <$> store <*> name <*> version <*> force)
            "Remove a specific version of a credential from the store."

        , mode "truncate"
            (DeleteAll <$> store <*> optional name <*> retain <*> force)
            "Remove multiple versions of credentials from the store. \
            \If no credential name is specified, it will operate on all \
            \credentials."
        ]

mode :: String -> Parser a -> String -> Mod CommandFields a
mode m p h = command m . info p $ fullDesc <> progDesc h <> header about

about :: String
about = "credentials - CLIistration CLI for credential and secret storage."

region :: Parser Region
region = option text
     ( short 'r'
    <> long "region"
    <> metavar "REGION"
    <> help "The AWS Region in which to operate. [default: eu-central-1]"
    <> value Frankfurt
    <> complete
     )

level :: Parser LogLevel
level = option (eitherReader r)
     ( short 'l'
    <> long "level"
    <> metavar "LEVEL"
    <> help "Log message level to emit. (trace|debug|info|error) [default: info]"
    <> value Info
    <> completeWith ["info", "error", "debug", "trace"]
     )
  where
    r "debug" = Right Debug
    r "trace" = Right Trace
    r "info"  = Right Info
    r "error" = Right Error
    r e       = Left $ "Unrecognised log level: " ++ e

store :: Parser Store
store = option text
     ( long "store"
    <> metavar "URI"
    <> help
        ("Protocol URI for the storage system. (proto://[address:port/]storage-ref) \
         \[default: " ++ string defaultStore ++ "].")
    <> value defaultStore
     )

key :: Parser KeyId
key = option text
    ( short 'k'
   <> long "key"
   <> metavar "STRING"
   <> help
       ("The KMS master key id to use. \
       \[default: " ++ string defaultKeyId ++ "]")
   <> value defaultKeyId
    )

context :: Parser Context
context = toContext $ option text
    ( short 'c'
   <> long "context"
   <> metavar "KEY=VALUE"
   <> help "A key/value pair to add to the encryption context."
    )

name :: Parser Name
name = option text
     ( short 'n'
    <> long "name"
    <> metavar "STRING"
    <> help "The unique name of the credential."
     )

version :: Parser Version
version = option text
     ( short 'v'
    <> long "version"
    <> metavar "NUMBER"
    <> help "A specific credential version."
    <> completeWith (map show ([1..9] :: [Int]))
     )

force :: Parser Force
force = flag Prompt NoPrompt
     ( short 'f'
    <> long "force"
    <> help "Always overwrite or remove, without an interactive prompt."
     )

format :: Parser Format
format = option text
     ( short 'o'
    <> long "format"
    <> metavar "FORMAT"
    <> help "Output format. (json|echo) [default: echo]"
    <> value Echo
    <> complete
     )

retain :: Parser Natural
retain = option text
     ( short 'k'
    <> long "keep"
    <> metavar "NUMBER"
    <> help "Number of versions to retain. [default: latest]"
    <> value 1
     )

input :: Parser Input
input = textual <|> filepath
  where
    textual = Raw
        <$> option text
             ( short 's'
            <> long "secret"
            <> metavar "STRING"
            <> help "The raw unencrypted value of the credential."
             )

    filepath = Path
        <$> option str
             ( short 'p'
            <> long "path"
            <> metavar "PATH"
            <> help "A path to read as the raw unencrypted value of the credential."
            <> action "file"
             )

text :: FromText a => ReadM a
text = eitherReader (fromText . Text.pack)

complete :: forall a f. (Data a, ToText a, HasCompleter f) => Mod f a
complete = completeWith $
    map (str . fromConstr) . dataTypeConstrs $ dataTypeOf val
  where
    val :: a
    val = undefined

    str :: a -> String
    str = string

string :: ToText a => a -> String
string = Text.unpack . toText
