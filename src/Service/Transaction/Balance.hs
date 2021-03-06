{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE DuplicateRecordFields    #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE PackageImports           #-}
{-# LANGUAGE RecordWildCards          #-}
{-# OPTIONS_GHC -fno-warn-orphans     #-}

module Service.Transaction.Balance
  ( getBalanceForKey,
    addMicroblockToDB,
    addMacroblockToDB,
    runLedger,
    writeMacroblockToDB
    ) where

import           Control.Concurrent.Chan.Unagi.Bounded
import           Control.Monad
import           Data.Aeson                            hiding (Error)
import           Data.Aeson.Types                      (parseMaybe)
import qualified Data.ByteString.Char8                 as BC
import           Data.Default                          (def)
import           Data.Hashable
import qualified Data.HashTable.IO                     as H
import           Data.List                             (sortBy)
import           Data.Maybe
import           Data.Ord                              (comparing)
import           Data.Pool
import qualified Data.Serialize                        as S (decode, encode)
import qualified "rocksdb-haskell" Database.RocksDB    as Rocks
import           Node.Data.GlobalLoging
import           Service.InfoMsg                       (InfoMsg (..),
                                                        LogingTag (..),
                                                        MsgType (..))
import           Service.Transaction.Storage
import           Service.Types
import           Service.Types.PublicPrivateKeyPair


instance Hashable PublicKey
type BalanceTable = H.BasicHashTable PublicKey Amount



getBalanceForKey :: DBPoolDescriptor -> PublicKey -> IO (Maybe Amount)
getBalanceForKey db key = do
    val  <- funR (poolLedger db) (S.encode key)
    result <- case val of Nothing -> return Nothing --putStrLn "There is no such key"
                          Just v  -> case (S.decode v :: Either String Amount ) of
                              Left _  -> error ("Can not decode balance" ++ show v)
                              Right b -> return $ Just b

    return result


updateBalanceTable :: BalanceTable -> Transaction -> IO ()
updateBalanceTable ht (Transaction fromKey toKey am _ _ _ _) = do
  v1 <- H.lookup ht $ fromKey
  v2 <- H.lookup ht $ toKey
  case (v1,v2) of
    (Nothing, _)       -> do return ()
    (_, Nothing)       -> do return ()
    (Just balanceFrom, Just balanceTo) -> if (balanceFrom - am) > 0
                                          then do
                                                  H.insert ht fromKey (balanceFrom - am)
                                                  H.insert ht toKey (balanceTo + am)
                                          else do return ()


getBalanceOfKeys :: Pool Rocks.DB -> [Transaction] -> IO BalanceTable
getBalanceOfKeys db tx = do
  let hashKeys = concatMap getPubKeys tx
      fun k = (\local_db -> Rocks.get local_db Rocks.defaultReadOptions (S.encode k))
      getBalanceByKey k = withResource db (fun k)
      toTuple k b = (,) k b
  balance  <- mapM (\k -> liftM (toTuple k ) (getBalanceByKey k)) hashKeys
  --   balance (key Maybe(S.encode Amount))

  -- initialize keys which does'not exist yet with initial balance = 100
  let keysWhichDoesNotExistYet = filter (\(_,v) -> v == Nothing) balance
      initialBalance = map (\(k,_) ->  (S.encode k, S.encode (100 :: Amount))) keysWhichDoesNotExistYet
      iBalance = map (\(key, val) -> Rocks.Put key val) initialBalance
      fun2 = (\local_db -> Rocks.write local_db def{Rocks.sync = True} iBalance)
  withResource db fun2
  --
  let fun3 = \(k,v) -> case v of Nothing -> (k, 100 :: Amount)
                                 Just aBalance -> case (S.decode aBalance :: Either String Amount) of
                                   Left _  -> (k, 0)
                                   Right b -> (k, b)

      newBalance = map fun3 balance
  aBalanceTable <- H.fromList newBalance
  return aBalanceTable


runLedger :: DBPoolDescriptor -> InChan InfoMsg -> Microblock -> IO ()
runLedger db aInfoChan m = do
    let txs = _transactions m
    ht      <- getBalanceOfKeys (poolLedger db) txs
    mapM_ (updateBalanceTable ht) txs
    writeLedgerDB (poolLedger db) aInfoChan ht


getPubKeys :: Transaction -> [PublicKey]
getPubKeys (Transaction fromKey toKey _ _ _ _ _) = [fromKey, toKey]


checkMacroblock :: DBPoolDescriptor -> InChan InfoMsg -> Microblock -> BC.ByteString -> BC.ByteString -> IO (Bool, Bool, Bool, Bool, MacroblockBD)
checkMacroblock db aInfoChan microblock keyBlockHash blockHash = do
    v  <- funR (poolMacroblock db) keyBlockHash
    case v of
      Nothing -> do -- If MacroblockBD is not already in the table, than insert it into the table
                    let aMacroBlock = dummyMacroblock {
                          _mblocks = [blockHash],
                          _teamKeys = _teamKeys (microblock :: Microblock)
                          } :: MacroblockBD
                    return (True, False, True, True, aMacroBlock)
      Just a -> -- If MacroblockBD already in the table
        case S.decode a :: Either String MacroblockBD of
          Left _  -> error "Can not decode MacroblockBD"
          Right bdMacroblock -> do
                   let hashes = _mblocks ( bdMacroblock :: MacroblockBD)
                   writeLog aInfoChan [BDTag] Info ("length hashes" ++ show(length hashes) ++ " " ++ show hashes)
                   if length hashes >= quantityMicroblocksInMacroblock
                   then if (length hashes == quantityMicroblocksInMacroblock)
                        then return (True, True, True, False, bdMacroblock)
                        else return (False, True, True, False, bdMacroblock)
                   else do
                     -- Check is Microblock already in MacroblockBD
                     let microblockIsAlreadyInMacroblock = blockHash `elem` hashes
                     writeLog aInfoChan [BDTag] Info ("Microblock is already in macroblock: " ++ show microblockIsAlreadyInMacroblock)
                     if microblockIsAlreadyInMacroblock
                       then return (True, False, False, True, bdMacroblock)  -- Microblock already in MacroblockBD - Nothing
                       else do -- add this Microblock to the value of MacroblockBD
                               let aMacroBlock = bdMacroblock {  _mblocks = hashes ++ [blockHash] } :: MacroblockBD
                               writeMacroblockToDB db aInfoChan keyBlockHash aMacroBlock
                             -- Check quantity of microblocks, can we close MacroblockBD?
                               if (length hashes >= (quantityMicroblocksInMacroblock - 1))
                                       then return (True, True, True, True, bdMacroblock)
                                       else return (True, False, True, True, bdMacroblock)


addMicroblockToDB :: DBPoolDescriptor -> Microblock -> InChan InfoMsg -> IO ()
addMicroblockToDB db m aInfoChan =  do
-- FIX: verify signature
    let txs = _transactions m
    let microblockHash = rHash $ tMicroblock2MicroblockBD  m
    writeLog aInfoChan [BDTag] Info ("New Microblock came" ++ show(microblockHash))
-- FIX: Write to db atomically
    (goOn, macroblockClosed, microblockNew, macroblockNew, macroblock ) <- checkMacroblock db aInfoChan m (_keyBlock (m :: Microblock)) microblockHash
    writeLog aInfoChan [BDTag] Info ("MacroblockBD - already closed " ++ show (not goOn))
    when goOn $ do
                writeLog aInfoChan [BDTag] Info ("MacroblockBD - New is " ++ show macroblockNew)
                writeLog aInfoChan [BDTag] Info ("Microblock - New is " ++ show microblockNew)
                writeLog aInfoChan [BDTag] Info ("MacroblockBD closed is " ++ show macroblockClosed)
                when (macroblockNew && microblockNew) $ do
                  writeMicroblockDB (poolMicroblock db) aInfoChan (tMicroblock2MicroblockBD m)
                  writeTransactionDB (poolTransaction db) aInfoChan txs microblockHash

                  if macroblockClosed then do
                    -- get all microblocks (without the last added) for macroblock
                    let microblockHashes = init $ _mblocks (macroblock :: MacroblockBD)
                    mbBD <- mapM (\h -> getMicroBlockByHashDB db (Hash h))  microblockHashes
                    let realMb =  map fromJust (filter (isJust) mbBD)
                    mbWithTx <- mapM (tMicroblockBD2Microblock db) realMb
                    let sortedMb = sortBy (comparing _sign) ((mbWithTx ++ [m]) :: [Microblock])
                    writeLog aInfoChan [BDTag] Info ("Start calculate Ledger "  ++ show (length (sortedMb :: [Microblock])))
                    mapM_ (runLedger db aInfoChan) (sortedMb :: [Microblock])
                    writeMacroblockToDB db aInfoChan (_keyBlock (m :: Microblock)) (macroblock {_reward = 10})
                  else do
                    writeMacroblockToDB db aInfoChan (_keyBlock (m :: Microblock)) macroblock


writeMacroblockToDB :: DBPoolDescriptor -> InChan InfoMsg -> BC.ByteString -> MacroblockBD -> IO ()
writeMacroblockToDB desc aInfoChan hashOfKeyBlock aMacroblock = do
  let key = hashOfKeyBlock
      val = S.encode aMacroblock
  funW (poolMacroblock desc) [(key,val)]
  writeLog aInfoChan [BDTag] Info ("Write Macroblock " ++ show key ++ " " ++ show aMacroblock ++ "to DB")
  funW (poolMacroblock desc) [(lastKeyBlock,key)]
  writeLog aInfoChan [BDTag] Info ("Write Last Macroblock " ++ show lastKeyBlock ++ "to DB")

writeMicroblockDB :: Pool Rocks.DB -> InChan InfoMsg -> MicroblockBD -> IO ()
writeMicroblockDB db aInfoChan m = do
  let key = rHash m
      val  = S.encode m
  funW db [(key,val)]
  writeLog aInfoChan [BDTag] Info ("Write Microblock "  ++ show key ++ "to Microblock table")


writeTransactionDB :: Pool Rocks.DB -> InChan InfoMsg -> [Transaction] -> BC.ByteString -> IO ()
writeTransactionDB dbTransaction aInfoChan txs hashOfMicroblock = do
  let txInfo = \tx1 num -> TransactionInfo tx1 hashOfMicroblock num
      txKeyValue = map (\(t,n) -> (rHashT t , S.encode (txInfo t n)) ) (zip txs [1..])
  funW dbTransaction txKeyValue
  writeLog aInfoChan [BDTag] Info ("Write Transactions to Transaction table")
  writeLog aInfoChan [BDTag] Info $ "Transactions: " ++ show (map (\t -> rHash t { _timestamp = Nothing }) txs)


writeLedgerDB ::  Pool Rocks.DB -> InChan InfoMsg -> BalanceTable -> IO ()
writeLedgerDB dbLedger aInfoChan bt = do
  ledgerKV <- H.toList bt
  let ledgerKeyValue = map (\(k,v)-> (S.encode k, S.encode v)) ledgerKV
  funW dbLedger ledgerKeyValue
  writeLog aInfoChan [BDTag] Info ("Write Ledger "  ++ show bt)


addMacroblockToDB :: DBPoolDescriptor -> Value -> InChan InfoMsg -> IO ()
addMacroblockToDB db (Object aValue) aInfoChan = do
  let keyBlock = case parseMaybe (.: "verb") aValue of
        Nothing     -> ""
        Just kBlock -> kBlock :: String --Map T.Text Value

  if keyBlock /= "kblock" then return ()
  else do
    let keyBlockInfoObject = case parseMaybe (.: "body") aValue of
            Nothing     -> error "Can not parse KeyBlockInfo" --Data.Map.empty
            Just kBlock -> kBlock :: KeyBlockInfo --Map T.Text Value

        keyBlockHash = rHash keyBlockInfoObject
    writeLog aInfoChan [BDTag] Info (show keyBlockInfoObject)

    val  <- funR (poolMacroblock db) keyBlockHash
    _ <- case val of
        Nothing -> return dummyMacroblock
        Just va  -> case S.decode va :: Either String MacroblockBD of
            Left _  -> error "Can not decode MacroblockBD"
            Right r -> return r

    writeMacroblockToDB db aInfoChan keyBlockHash $ tKeyBlockInfo2Macroblock keyBlockInfoObject
addMacroblockToDB _ x aInfoChan = writeLog aInfoChan [ServePoATag] Error ("Can not decode KeyBlockInfo" ++ show x)
