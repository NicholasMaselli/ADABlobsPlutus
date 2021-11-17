{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE BangPatterns               #-}

{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Auction where

import           Control.Monad        hiding (fmap)
import           Data.Aeson           (ToJSON, FromJSON)
import           Data.List.NonEmpty   (NonEmpty (..))
import           Data.Map             as Map
import           Data.Text            (pack, Text)
import           GHC.Generics         (Generic)
import           Plutus.Contract
import           Plutus.ChainIndex.Tx
import qualified PlutusTx             as PlutusTx
import           PlutusTx.Prelude     hiding (Semigroup(..), unless)
import           PlutusTx.Prelude     (divide)
import qualified PlutusTx.Prelude     as Plutus
import           Ledger               hiding (singleton)
import           Ledger.Constraints   as Constraints
import qualified Ledger.Scripts       as Scripts
import qualified Ledger.Typed.Scripts as Scripts hiding (validatorHash)
import           Ledger.Value         as Value
import           Ledger.Ada           as Ada hiding (divide)
import           Playground.Contract  (ensureKnownCurrencies, printSchemas, stage, printJson)
import           Playground.TH        (mkKnownCurrencies, mkSchemaDefinitions)
import           Playground.Types     (KnownCurrency (..))
import           Prelude              (IO, Semigroup (..), Show (..), String)
import           Schema               (ToSchema)
import           Text.Printf          (printf)

--------------------------------------------------------------------------------------------------
-- On Chain Code
--------------------------------------------------------------------------------------------------
data AuctionDetails = AuctionDetails 
    { adSeller             :: !PubKeyHash
    , adCurrency           :: !CurrencySymbol
    , adToken              :: !TokenName
    , adBid                :: !Integer
    , adBidPercentIncrease :: !Integer --5
    , adStartTime          :: !POSIXTime -- 1596000000000 (For the playground only)
    , adBidTimeIncrement   :: !POSIXTime -- 172800000 (3 extra 0s because I think milliseconds are included for Plutus
    } deriving (Show, Generic, ToJSON, FromJSON, ToSchema)

instance Eq AuctionDetails where
    {-# INLINABLE (==) #-}
    a == b = (adSeller             a == adSeller                  b) &&
             (adCurrency           a == adCurrency                b) &&
             (adToken              a == adToken                   b) &&
             (adBid                a == adBid                     b) &&
             (adBidPercentIncrease a == adBidPercentIncrease      b) &&
             (adStartTime          a == adStartTime               b) &&
             (adBidTimeIncrement   a == adBidTimeIncrement        b)

PlutusTx.unstableMakeIsData ''AuctionDetails -- Make Stable when live
PlutusTx.makeLift ''AuctionDetails

data BidDetails = BidDetails
    { bdBidder :: !PubKeyHash
    , bdBid    :: !Integer    
    , bdTime   :: !POSIXTime
    } deriving Show

instance Eq BidDetails where
    {-# INLINABLE (==) #-}
    a == b = (bdBidder a == bdBidder b) &&
             (bdBid    a == bdBid    b)

PlutusTx.unstableMakeIsData ''BidDetails -- Make Stable when live
PlutusTx.makeLift ''BidDetails

data CloseDetails = CloseDetails
    { cdCloser :: !PubKeyHash
    } deriving Show

instance Eq CloseDetails where
    {-# INLINABLE (==) #-}
    a == b = (cdCloser a == cdCloser b)
             
PlutusTx.unstableMakeIsData ''CloseDetails -- Make Stable when live
PlutusTx.makeLift ''CloseDetails

data AuctionDatum = AuctionDatum
    { adAuctionDetails :: !AuctionDetails
    , adHighestBid     :: !BidDetails
    } deriving Show

PlutusTx.unstableMakeIsData ''AuctionDatum -- Make Stable when live
PlutusTx.makeLift ''AuctionDatum

data AuctionRedeemer = Auction AuctionDetails | Bid BidDetails | Close CloseDetails
    deriving Show

PlutusTx.unstableMakeIsData ''AuctionRedeemer -- Make Stable when live
PlutusTx.makeLift ''AuctionRedeemer

data Auctioning
instance Scripts.ValidatorTypes Auctioning where
    type instance DatumType Auctioning = AuctionDatum
    type instance RedeemerType Auctioning = AuctionRedeemer

-- Returns an Integer whose value is 'percent' percent greater than input (rounded down)
{-# INLINABLE increasePercent #-} 
increasePercent :: Integer -> Integer -> Integer
increasePercent input percent = (input * (100 + percent)) `divide` 100

-- New Bid must be greater than current bid + 5% rounded down
{-# INLINABLE minBid #-}
minBid :: AuctionDatum -> Integer
minBid AuctionDatum{..} = increasePercent (bdBid adHighestBid) (adBidPercentIncrease adAuctionDetails)

{-# INLINABLE deadline #-}
deadline :: AuctionDatum -> POSIXTime
deadline AuctionDatum{..} = (bdTime adHighestBid) + (adBidTimeIncrement adAuctionDetails) 

{-# INLINABLE mkAuctionValidator #-}
mkAuctionValidator :: AuctionDatum -> AuctionRedeemer -> ScriptContext -> Bool
mkAuctionValidator datum redeemer context =    
    case redeemer of
        Bid bd@BidDetails{..}     ->
            traceIfFalse "Wrong output datum"                                               (correctBidOutputDatum bd) &&
            traceIfFalse "Wrong output value"                                               (correctBidOutputValue bdBid) &&
            --traceIfFalse "Bid is too early, the auction has not started yet"              (correctSlotRangeStartAuction) &&
            --traceIfFalse "Bid is too late, the auction has ended"                         (correctSlotRangeEndAuction) &&
            traceIfFalse "Bid is too low, must be at least 5% greater than the current bid" (sufficientBid bdBid) &&
            traceIfFalse "Wrong refund amount"                                              (correctBidRefund)
        Close cd@CloseDetails{..} ->
            traceIfFalse "Seller must close the auction"                                    (isSeller cd) && -- This is required until the time interval bug in plutus 1.30.1 is fixed 
            --traceIfFalse "The auction has not ended yet"                                    (correctSlotRangeCloseEndAuction) &&
            traceIfFalse "Expected the highest bidder to get the token" (getsValue (bdBidder (adHighestBid datum)) tokenValue) &&
            traceIfFalse "Expected the sell to get the highest bid" (getsValue (adSeller (adAuctionDetails datum)) (Ada.lovelaceValueOf (bdBid (adHighestBid datum)))) 
    where
        --------------------------------------------------------------------------------------------------
        -- Helper Functions
        --------------------------------------------------------------------------------------------------
        txInfo :: TxInfo
        txInfo = scriptContextTxInfo context

        tokenValue :: Value
        tokenValue = Value.singleton (adCurrency (adAuctionDetails datum)) (adToken (adAuctionDetails datum)) 1

        ownOutput   :: TxOut
        outputDatum :: AuctionDatum
        (ownOutput, outputDatum) = case getContinuingOutputs context of
            [output] -> case txOutDatumHash output of
                Nothing        -> traceError "Wrong output type"
                Just datumHash -> case findDatum datumHash txInfo of
                    Nothing        -> traceError "Datum not found"
                    Just (Datum d) ->  case PlutusTx.fromBuiltinData d of
                        Just auctionDatum -> (output, auctionDatum)
                        Nothing           -> traceError "Error decoding data"
            _   -> traceError "Expected exactly one continuing output"

        isSeller :: CloseDetails -> Bool
        isSeller closeDetails = (cdCloser closeDetails) == (adSeller (adAuctionDetails datum))

        --------------------------------------------------------------------------------------------------
        -- Time Functions
        --------------------------------------------------------------------------------------------------
        
        -- There is a bug in the "to" time intervals in Plutus 1.30.1 where the "to" does not work. using static time for now
        --correctSlotRangeBidStartAuction :: Bool
        --correctSlotRangeBidStartAuction = from (adStartTime (adAuctionDetails datum)) `contains` txInfoValidRange txInfo

        --correctSlotRangeBidEndAuction :: Bool
        --correctSlotRangeBidEndAuction = to (deadline datum) `contains` txInfoValidRange txInfo

        correctSlotRangeCloseEndAuction :: Bool
        correctSlotRangeCloseEndAuction = from (deadline datum) `contains` txInfoValidRange txInfo

        --------------------------------------------------------------------------------------------------
        -- Data Functions
        --------------------------------------------------------------------------------------------------
        correctBidOutputDatum :: BidDetails -> Bool
        correctBidOutputDatum bid = (adAuctionDetails datum == adAuctionDetails outputDatum)   &&
                                    (adHighestBid outputDatum == bid)

        correctBidOutputValue :: Integer -> Bool
        correctBidOutputValue amount = txOutValue ownOutput == tokenValue Plutus.<> Ada.lovelaceValueOf amount

        --------------------------------------------------------------------------------------------------
        -- Value Functions
        --------------------------------------------------------------------------------------------------
        sufficientBid :: Integer -> Bool
        sufficientBid amount = amount > minBid datum

        correctBidRefund :: Bool
        correctBidRefund =
                let 
                    outputs = [output 
                              | output <- (txInfoOutputs txInfo)
                              , (txOutAddress output) == (pubKeyHashAddress (bdBidder (adHighestBid datum)))
                              ]
                in 
                    case outputs of
                        [output] -> txOutValue output == Ada.lovelaceValueOf (bdBid (adHighestBid datum))
                        _        -> traceError "Expected exactly one refund output"

        getsValue :: PubKeyHash -> Value -> Bool
        getsValue publicKeyHash value =
            let
                [output] = [ ouput'
                           | ouput' <- txInfoOutputs txInfo
                           , txOutValue ouput' == value
                           ]
            in
                txOutAddress output == pubKeyHashAddress publicKeyHash

auctionTypedValidator :: Scripts.TypedValidator Auctioning
auctionTypedValidator = Scripts.mkTypedValidator @Auctioning
    $$(PlutusTx.compile [|| mkAuctionValidator ||])
    $$(PlutusTx.compile [|| wrap ||])
  where
    wrap = Scripts.wrapValidator @AuctionDatum @AuctionRedeemer

auctionValidator :: Validator
auctionValidator = Scripts.validatorScript auctionTypedValidator

auctionAddress :: Ledger.ValidatorHash
auctionAddress = Scripts.validatorHash auctionValidator

--------------------------------------------------------------------------------------------------
-- Off Chain Code
--------------------------------------------------------------------------------------------------
data StartParams = StartParams
    { spCurrency             :: !CurrencySymbol
    , spToken                :: !TokenName
    , spBid                  :: !Integer
    , spBidPercentIncrease   :: !Integer
    , spStartTime            :: !POSIXTime
    , spBidTimeIncrement     :: !POSIXTime
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

data BidParams = BidParams
    { bpCurrency :: !CurrencySymbol
    , bpToken    :: !TokenName
    , bpBid      :: !Integer
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

data CloseParams = CloseParams
    { cpCurrency :: !CurrencySymbol
    , cpToken    :: !TokenName
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

type AuctionSchema = 
        Endpoint "start" StartParams
    .\/ Endpoint "bid"   BidParams 
    .\/ Endpoint "close" CloseParams   

start :: AsContractError e => Promise () AuctionSchema e ()
start = endpoint @"start" @StartParams $ \(StartParams{..}) -> do
    logInfo @String (printf "Inside the start endpoint")
    pkh <- Plutus.Contract.ownPubKeyHash --pubKeyHash <$> Plutus.Contract.ownPubKey
    let auctionDetails = AuctionDetails
                            { adSeller             = pkh
                            , adCurrency           = spCurrency
                            , adToken              = spToken
                            , adBid                = spBid
                            , adBidPercentIncrease = spBidPercentIncrease
                            , adStartTime          = spStartTime
                            , adBidTimeIncrement   = spBidTimeIncrement
                            }
        auctionDatum   = AuctionDatum
                             { adAuctionDetails = auctionDetails
                             , adHighestBid     = BidDetails { bdBidder = pkh, bdBid = spBid, bdTime = spStartTime }
                             } 
        value          = Value.singleton spCurrency spToken 1 <> Ada.lovelaceValueOf spBid
        tx             = Constraints.mustPayToTheScript auctionDatum value
    --ledgerTx <- submitTxConstraints auctionTypedValidator tx
    --void (awaitTxConfirmed (txId ledgerTx))
    void (submitTxConstraints auctionTypedValidator tx)
    logInfo @String $ printf "Started auction %s for token %s" (show auctionDetails) (show value)

bid :: AsContractError e => Promise () AuctionSchema e ()
bid = endpoint @"bid" @BidParams $ \(BidParams{..}) -> do
    logInfo @String (printf "Starting bid endpoint")
    (outputReference, chainTxOut, auctionDatum@AuctionDatum{..}) <- findAuction bpCurrency bpToken

    now <- currentTime
    --if bpBid < (minBid auctionDatum) then traceError "Bid is lower than the minimum bid (%d)" (minBid auctionDatum)
    --else if now > (deadline auctionDatum) then traceError "Dealine has passed at (%s)" (deadline auctionDatum)
    --else do     
    pkh <- Plutus.Contract.ownPubKeyHash --pubKeyHash <$> Plutus.Contract.ownPubKey
    logInfo @String (printf "Making bid at (%s) the deadline is at (%s)" (show now) (show (deadline auctionDatum)))
    let bid             = BidDetails   { bdBidder = pkh, bdBid = bpBid, bdTime = now }
        newAuctionDatum = AuctionDatum { adAuctionDetails = adAuctionDetails
                                       , adHighestBid = bid
                                       }
        value           = Value.singleton bpCurrency bpToken 1 <> Ada.lovelaceValueOf bpBid
        redeemer        = Redeemer (PlutusTx.toBuiltinData (Bid bid))
        lookups         = Constraints.typedValidatorLookups auctionTypedValidator <>
                          Constraints.otherScript auctionValidator                <>
                          Constraints.unspentOutputs (Map.singleton outputReference chainTxOut)
        tx              = mustPayToTheScript newAuctionDatum value <>
                          mustPayToPubKey (bdBidder adHighestBid) (Ada.lovelaceValueOf (bdBid adHighestBid)) <>
                          --mustValidateIn (from (adStartTime adAuctionDetails)) <> -- Uncomment this after time interval bug is fixed (bug in plutus 1.30.1)
                          mustSpendScriptOutput outputReference redeemer
    --ledgerTx <- submitTxConstraintsWith lookups tx
    --void (awaitTxConfirmed (txId ledgerTx))
    void (submitTxConstraintsWith lookups tx)
    logInfo @String $ printf "Made bid of %d lovelace in auction %s for token (%s, %s) at time (%s), deadline is now (%s)"
        bpBid
        (show adAuctionDetails)
        (show bpCurrency)
        (show bpToken)
        (show now)
        (show (deadline newAuctionDatum))

close :: AsContractError e => Promise () AuctionSchema e ()
close = endpoint @"close" @CloseParams $ \(CloseParams{..}) -> do
    logInfo @String (printf "Starting close endpoint")
    (outputReference, chainTxOut, auctionDatum@AuctionDatum{..}) <- findAuction cpCurrency cpToken
    
    pkh <- Plutus.Contract.ownPubKeyHash --pubKeyHash <$> Plutus.Contract.ownPubKey
    now <- currentTime
    --if now < (deadline auctionDatum) then traceError "Dealine at (%s) has not passed yet" (deadline auctionDatum)
    --else do
    logInfo @String (printf "Closing at (%s) the deadline is at (%s)" (show now) (show (deadline auctionDatum)))
    let value    = Value.singleton cpCurrency cpToken 1
        cd       = CloseDetails   { cdCloser = pkh }
        redeemer = Redeemer (PlutusTx.toBuiltinData (Close cd))
        seller   = adSeller adAuctionDetails
        lookups  = Constraints.typedValidatorLookups auctionTypedValidator <>
                   Constraints.otherScript auctionValidator                <>
                   Constraints.unspentOutputs (Map.singleton outputReference chainTxOut)
        tx       = mustPayToPubKey (bdBidder adHighestBid) value <>
                   mustPayToPubKey seller (Ada.lovelaceValueOf (bdBid adHighestBid)) <>
                   --mustValidateIn (from deadline) <> -- Uncomment this after time interval bug is fixed (bug in plutus 1.30.1)
                   mustSpendScriptOutput outputReference redeemer
    --ledgerTx <- submitTxConstraintsWith lookups tx
    --void (awaitTxConfirmed (txId ledgerTx))
    void (submitTxConstraintsWith lookups tx)
    logInfo @String $ printf "Closed auction %s for token (%s, %s) at time (%s)"
        (show adAuctionDetails)
        (show cpCurrency)
        (show cpToken)
        (show now)

findAuction :: AsContractError e => CurrencySymbol -> TokenName -> Contract w s e (TxOutRef, ChainIndexTxOut, AuctionDatum)
findAuction currencySymbol tokenName = do
    utxos <- utxosTxOutTxAt (scriptAddress auctionValidator)
    let xs = [ (outputReference, (chainTxOut, chainTx))
             | (outputReference, (chainTxOut, chainTx)) <- Map.toList utxos
             , Value.valueOf (txOutValue (toTxOut chainTxOut)) currencySymbol tokenName == 1             
             ]
    case xs of
        [(outputReference, (chainTxOut, chainTx))] -> case txOutDatumHash (toTxOut chainTxOut) of
            Nothing        -> traceError "Unexpected out type"
            Just datumHash -> case Map.lookup datumHash (getDatumMap chainTx) of
                Nothing        -> traceError "Datum not found"
                Just (Datum e) -> case PlutusTx.fromBuiltinData e of
                    Nothing -> traceError "Datum has wrong type"
                    Just datum@AuctionDatum{..}
                        | adCurrency adAuctionDetails == currencySymbol && adToken adAuctionDetails == tokenName -> return (outputReference, chainTxOut, datum)
                        | otherwise                                                  -> traceError "Auction token mismatch"
        _                     -> traceError "Auction utxo not found"  

getDatumMap :: ChainIndexTx -> Map DatumHash Datum
getDatumMap chainTx = _citxData chainTx

contract :: AsContractError e => Contract () AuctionSchema e ()
contract = selectList [start, bid, close]

endpoints :: AsContractError e => Contract () AuctionSchema e ()
endpoints = contract

mkSchemaDefinitions ''AuctionSchema

myToken :: KnownCurrency
myToken = KnownCurrency (ValidatorHash "f") "Token" (TokenName "T" :| [])

mkKnownCurrencies ['myToken]


{-
test :: IO()
test = runEmulatorTradeIO myTrace

myTrace :: EmulatorTrace()
myTrace = do
    h1 <- activateContractWallet (Wallet 1) endpoints
    h2 <- activateContractWallet (Wallet 2) endpoints
    callEndpoint @"start" h1 $ StartParams
        {
            spCurrency = 66,
            spToken = "T",
            spBid = 100,
            spBidPercentIncrease = 5,
            spStartTime = 1596000000000,
            spBidTimeIncrement = 172800000,
        }

    void $ waitUntilSlot 20

    callEndpoint @"bid" h2 $ BidParam
        {
            spCurrency = 66,
            spToken = "T",
            spBid = 5000,
        }

    void $ waitNSlots 1

    callEndpoint @"close" h1 $ CloseParams
        {
            spCurrency = 66,
            spToken = "T",
        }

    void $ waitNSlots 1
-}