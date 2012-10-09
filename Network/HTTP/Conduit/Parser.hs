{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Network.HTTP.Conduit.Parser
    ( sinkHeaders
    , newline
    , parserHeadersFromByteString
    , parseChunkHeader
    ) where

import Prelude hiding (take, takeWhile)
import Control.Applicative
import Data.Word (Word8)

import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8

import Data.Attoparsec

import Data.Conduit.Attoparsec (sinkParser)
import Data.Conduit (Sink, MonadResource, MonadThrow)
import Control.Monad (when)


type Header = (S.ByteString, S.ByteString)

parseHeader :: Parser Header
parseHeader = do
    k <- takeWhile1 notNewlineColon
    _ <- word8 58 -- colon
    skipWhile isSpace
    v <- takeWhile notNewline
    newline
    return (k, v)

notNewlineColon, isSpace, isNumber, notNewline :: Word8 -> Bool

notNewlineColon 10 = False -- LF
notNewlineColon 13 = False -- CR
notNewlineColon 58 = False -- colon
notNewlineColon _  = True

isSpace 32 = True
isSpace _  = False

isNumber i = 0x30 <= i && i <= 0x39

notNewline 10 = False
notNewline 13 = False
notNewline _  = True

newline :: Parser ()
newline =
    lf <|> (cr >> lf)
  where
    word8' x = word8 x >> return ()
    lf = word8' 10
    cr = word8' 13

parseHeaders :: Parser (Status, [Header])
parseHeaders = do
    s <- parseStatus <?> "HTTP status line"
    h <- manyTill parseHeader newline <?> "Response headers"
    return (s, h)

sinkHeaders :: (MonadThrow m, MonadResource m) => Sink S.ByteString m (Status, [Header])
sinkHeaders = sinkParser parseHeaders


parserHeadersFromByteString :: Monad m => S.ByteString -> m (Either String (Status, [Header]))
parserHeadersFromByteString s = return $ parseOnly parseHeaders s


type Status = (S.ByteString, Int, S.ByteString)

parseStatus :: Parser Status
parseStatus = do
    end <- atEnd
    when end $ fail "EOF reached"
    _ <- manyTill (take 1 >> return ()) (try $ string "HTTP/") <?> "HTTP/"
    ver <- takeWhile1 $ not . isSpace
    _ <- word8 32 -- space
    statCode <- takeWhile1 isNumber
    statCode' <-
        case reads $ S8.unpack statCode of
            [] -> fail $ "Invalid status code: " ++ S8.unpack statCode
            (x, _):_ -> return x
    statMsg <- try (word8 32 >> takeWhile notNewline) <|> return ""
    newline
    if (statCode == "100")
        then newline >> parseStatus
        else return (ver, statCode', statMsg)

parseChunkHeader :: Parser Int
parseChunkHeader = do
    len <- hexs
    skipWhile isSpace
    newline <|> attribs
    return len

attribs :: Parser ()
attribs = do
    _ <- word8 59 -- colon
    skipWhile notNewline
    newline

hexs :: Parser Int
hexs = do
    ws <- many1 hex
    return $ foldl1 (\a b -> a * 16 + b) $ map fromIntegral ws

hex :: Parser Word8
hex =
    (digit <|> upper <|> lower) <?> "Hexadecimal digit"
  where
    digit = do
        d <- satisfy $ \w -> (w >= 48 && w <= 57)
        return $ d - 48
    upper = do
        d <- satisfy $ \w -> (w >= 65 && w <= 70)
        return $ d - 55
    lower = do
        d <- satisfy $ \w -> (w >= 97 && w <= 102)
        return $ d - 87