
{-# OPTIONS_GHC -Wno-orphans -Wno-missing-export-lists -Wno-missing-monadfail-instances #-}

module Lorentz.Contracts.Util where

import Data.Char
import Data.Functor.Classes
import GHC.TypeLits (KnownSymbol, symbolVal)
import Prelude hiding (readEither, unlines, unwords)
import Text.ParserCombinators.ReadP (ReadP)
import Text.Read
import qualified Text.ParserCombinators.ReadP as P

import Data.Aeson
-- import qualified Data.Aeson as Aeson
-- import qualified Data.Aeson.Encoding as Aeson
import qualified Data.Text as T

import Lorentz.Value
import Lorentz.Macro
import Lorentz.Constraints
-- import Michelson.Typed.Haskell.Value
import Michelson.Typed.Instr (Instr)
import Michelson.Typed.Value
import Named
import Tezos.Address
import Tezos.Crypto
import qualified Tezos.Crypto.Ed25519 as Ed25519
import qualified Tezos.Crypto.Secp256k1 as Secp256k1
import qualified Tezos.Crypto.P256 as P256
-- import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Lorentz.Contracts.ManagedLedger as ManagedLedger

-- deriving instance Read KeyHash

instance IsoValue (Value' Instr t) where
  type ToT (Value' Instr t) = t
  toVal = id
  fromVal = id

instance IsoCValue (CValue t) where
  type ToCT (CValue t) = t
  toCVal = id
  fromCVal = id


-- | Parse something between the two given `Char`'s
betweenChars :: Char -> Char -> ReadP a -> ReadP a
betweenChars beforeChar afterChar =
  P.char beforeChar `P.between` P.char afterChar

-- | Parse something in parentheses
inParensP :: ReadP a -> ReadP a
inParensP = '(' `betweenChars` ')'

-- | Parse something in double-quotes: @"[something]"@
inQuotesP :: ReadP a -> ReadP a
inQuotesP = '"' `betweenChars` '"'

-- | Attempt to parse with given modifier, otherwise parse without
maybeLiftP :: (ReadP a -> ReadP a) -> ReadP a -> ReadP a
maybeLiftP liftP = liftM2 (<|>) liftP id

-- | Attempt to parse `inParensP`, else parse without
maybeInParensP :: ReadP a -> ReadP a
maybeInParensP = maybeLiftP inParensP

-- | Attempt to parse `inQuotesP`, else parse without
maybeInQuotesP :: ReadP a -> ReadP a
maybeInQuotesP = maybeLiftP inQuotesP

-- | Read an `Address`, inside or outside of @""@'s
readAddressP :: ReadP Address
readAddressP =
      maybeInParensP . maybeInQuotesP $ do
        ensureAddressPrefix
        addressStr <- P.munch1 isAlphaNum
        case parseAddress $ T.pack addressStr of
          Left err -> fail $ show err
          Right address' -> return address'
  where
    ensureAddressPrefix =
      (do {('t':'z':'1':_) <- P.look; return ()}) <|>
      (do {('K':'T':'1':_) <- P.look; return ()})

instance Read ManagedLedger.Parameter where
  readPrec =
    choice
      [ readUnaryWith (parens readPrec) "Transfer" ManagedLedger.Transfer
      , readUnaryWith (parens readPrec) "Approve" ManagedLedger.Approve
      , readUnaryWith (parens readPrec) "GetAllowance" ManagedLedger.GetAllowance
      , readUnaryWith (parens readPrec) "GetBalance" ManagedLedger.GetBalance
      , readUnaryWith (parens readPrec) "GetTotalSupply" ManagedLedger.GetTotalSupply
      , readUnaryWith (parens readPrec) "SetPause" ManagedLedger.SetPause
      , readUnaryWith (parens readPrec) "SetAdministrator" ManagedLedger.SetAdministrator
      , readUnaryWith (parens readPrec) "GetAdministrator" ManagedLedger.GetAdministrator
      , readUnaryWith (parens readPrec) "Mint" ManagedLedger.Mint
      , readUnaryWith (parens readPrec) "Burn" ManagedLedger.Burn
      ]

instance Read Address where
  readPrec = readP_to_Prec $ const readAddressP

instance NiceParameter cp => Read (ContractRef cp) where
  readPrec =
    readP_to_Prec . const $ do
      P.string "ContractRef"
      P.skipSpaces
      toContractRef <$> readAddressP

instance (Read a, NiceParameter r) => Read (View a r) where
  readPrec =
    readP_to_Prec $ \prec' -> do
      P.skipSpaces
      P.string "View"
      P.skipSpaces
      viewArg <- readPrec_to_P (parens readPrec) prec'
      P.skipSpaces
      View viewArg . toContractRef <$> readAddressP

instance (Read a, KnownSymbol name) => Read (NamedF Identity a name) where
  -- show (ArgF a) = symbolVal (Proxy @name) <> " :! " <> show a
  readPrec = readPrec' Proxy
    where
      readPrec' ::
           (Read a', KnownSymbol name')
        => proxy name'
        -> ReadPrec (NamedF Identity a' name')
      readPrec' nameProxy =
        readP_to_Prec $ \prec' -> do
          P.skipSpaces
          maybeInQuotesP . P.string $ symbolVal nameProxy
          P.skipSpaces
          P.string ".!"
          P.skipSpaces
          ArgF <$> readPrec_to_P readPrec prec'

instance Read PublicKey where
  readPrec = readP_to_Prec $ \_ ->
    maybeInQuotesP $ do
      eNonQuoteChars <- parsePublicKey . T.pack <$> P.munch1 isAlphaNum
      case eNonQuoteChars of
        Left err -> fail $ show err
        Right res -> return res

-- instance Read SecretKey where
--   readPrec = readP_to_Prec $ \_ ->
--     maybeInQuotesP $ do
--       eNonQuoteChars <- parseSecretKey . T.pack <$> P.munch1 isAlphaNum
--       case eNonQuoteChars of
--         Left err -> fail $ show err
--         Right res -> return res

instance Read Signature where
  readPrec = readP_to_Prec $ \_ ->
    maybeInQuotesP $ do
      eNonQuoteChars <- parseSignature . T.pack <$> P.munch1 isAlphaNum
      case eNonQuoteChars of
        Left err -> fail $ show err
        Right res -> return res

-- | Since `Ed25519.PublicKey` doesn't expose
-- many instances, we convert to `String` and
-- compare the results
instance Ord Ed25519.PublicKey where
  compare x y = show x `compare` (show y :: String)

-- | Since `Secp256k1.PublicKey` doesn't expose
-- many instances, we convert to `String` and
-- compare the results
instance Ord Secp256k1.PublicKey where
  compare x y = show x `compare` (show y :: String)

-- | Since `P256.PublicKey` doesn't expose
-- many instances, we convert to `String` and
-- compare the results
instance Ord P256.PublicKey where
  compare x y = show x `compare` (show y :: String)

deriving instance Ord PublicKey


-- instance ToJSON Ed25519.PublicKey where
--   toJSON = Aeson.String . formatPublicKey . PublicKeyEd25519
--   toEncoding = Aeson.text . formatPublicKey . PublicKeyEd25519

-- instance FromJSON Ed25519.PublicKey where
--   parseJSON =
--     Aeson.withText "PublicKey" $
--     either (fail . show) (pure . unPublicKey) . parsePublicKey


-- instance ToJSONKey Ed25519.PublicKey where
-- instance FromJSONKey Ed25519.PublicKey where

instance ToJSONKey PublicKey where
  -- toJSONKey = contramap _ toJSONKey
  -- toJSONKeyList = contramap (fmap _) toJSONKeyList

instance FromJSONKey PublicKey where
  -- fromJSONKey = fmap _ fromJSONKey
  -- fromJSONKeyList = fmap (fmap _) fromJSONKeyList

