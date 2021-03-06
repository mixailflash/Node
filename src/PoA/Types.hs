{-# LANGUAGE
        OverloadedStrings
    ,   ScopedTypeVariables
    ,   DuplicateRecordFields
    ,   FlexibleInstances
    ,   DeriveGeneric
    ,   GeneralizedNewtypeDeriving
    ,   StandaloneDeriving
  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module PoA.Types where

import              Data.Word()
import qualified    Data.ByteString as B
import qualified    Data.ByteString.Char8 as CB
import              Data.Aeson
import              Data.String
import              GHC.Generics
import qualified    Data.Text as T
import              Data.Hex
import              Data.Maybe
import              Control.Monad.Extra
import qualified    Data.Serialize as S
import              Service.Types (Microblock(..), Transaction)
import              Service.Network.Base
import              Data.IP
import              Node.Data.Key
import              Service.Types.SerializeJSON()
import              Service.Types.SerializeInstances
import              Data.Either
import              Text.Read
import              Crypto.PubKey.ECC.ECDSA

data PPToNNMessage
    -- Requests:
    -- transactions receiving.
    = RequestTransaction { ---
        number :: Int
    }

    -- receive PoW nodes' list
    | RequestPoWList

    -- send broadcast
    | RequestBroadcast { ---
        recipientType :: NodeType,
        msg           :: Value
    }
    -- get connects
    | RequestConnects Bool

    -- responses with PPId
    | ResponseNodeIdToNN NodeId NodeType

    -- Messages:
    -- For other PoA/PoW node.
    | MsgMsgToNN { ----
        destination :: NodeId,
        msg :: Value
    }

    -- new microblock was mined.
    | MsgMicroblock {
        microblock :: Microblock
    }

    | ActionNodeStillAliveTest PortNumber HostAddress
    | IsInPendingRequest Transaction
    | GetPendingRequest
    | AddTransactionRequest Transaction
    | ActionAddToListOfConnects Int
    | NNConnection PortNumber PublicPoint NodeId
    | CNConnection NodeType (Maybe NodeId)
    | RequestActualConnectList

    deriving (Show)

data NodeType = PoW | PoA | All | NN deriving (Eq, Show, Ord, Generic)

instance S.Serialize NodeType

-- PP means PoW and PoA
-- MsgToMainActorFromPP

data BNResponseConnects = BNResponseConnects [Connect]
data BNRequestConnects  = BNRequestConnects


instance FromJSON BNResponseConnects where
    parseJSON (Object aMsg) = BNResponseConnects <$> (aMsg .: "connects")


instance ToJSON BNRequestConnects where
    toJSON BNRequestConnects = object [
        "tag"       .= ("Request"  :: String),
        "type"      .= ("Connects"  :: String)
      ]


data NNToPPMessage
    = RequestNodeIdToPP

    | ResponseConnects [Connect]
    | ResponseTransaction {
        transaction :: Transaction
    }

    -- request with PoW's list
    | ResponsePoWList {
        poWList :: [NodeId]
    }

    | MsgMsgToPP {
        sender :: NodeId,
        message :: Value
    }

    | MsgBroadcastMsg {
        message :: Value,
        idFrom  :: IdFrom
    }

    | MsgNewNodeInNet NodeId NodeType (Maybe Connect)
    | ResponsePendingTransactions [Transaction]
    | ResponseIsInPending Bool
    | ResponseTransactionValid Bool
    | ResponseClientId NodeId
    | ActualConnectList [ActualConnectInfo]


{-
data MsgToSenderActor where
    KillSenderActor :: MsgToSenderActor
    ...
    ...
    ...
    MsgToClientNode :: MsgToClientNode -> MsgToSenderActor

-}

data ActualConnectInfo = ActualConnectInfo NodeId NodeType (Maybe Connect)


instance ToJSON ActualConnectInfo where
    toJSON (ActualConnectInfo aNodeId aNodeType (Just (Connect aIp aPortNumber))) = object [
            "node_type" .= show aNodeType
        ,   "node_id"   .= nodeIdToUnxed aNodeId
        ,   "ip"        .= show (fromHostAddress aIp)
        ,   "port"      .= fromEnum aPortNumber
      ]
    toJSON (ActualConnectInfo aNodeId aNodeType Nothing) = object [
            "node_type" .= show aNodeType
        ,   "node_id"   .= nodeIdToUnxed aNodeId
      ]



instance FromJSON ActualConnectInfo where
    parseJSON (Object aMsg) = do
        aNodeType :: T.Text  <- aMsg .: "node_type"
        aUnxedId  :: T.Text  <- aMsg .: "node_id"
        aNodeId   <- unhexNodeId aUnxedId

        aIp       <- aMsg .:? "ip"
        aPort     <- aMsg .:? "port"

        let aConnect = do
                aIpAdress <- readMaybe =<< aIp
                aJustPort <- aPort
                return $ Connect (toHostAddress aIpAdress) (toEnum aJustPort)
        return $ ActualConnectInfo aNodeId (readNodeType aNodeType) aConnect



myUnhex :: IsString a => T.Text -> Either a String
myUnhex aString = case unhex $ T.unpack aString of
    Just aDecodeString  -> Right aDecodeString
    Nothing             -> Left "Nothing"


unhexNodeId :: MonadPlus m => T.Text -> m NodeId
unhexNodeId aString = case unhex . fromString . T.unpack $ aString of
    Just aDecodeString  -> return . NodeId . roll $ B.unpack aDecodeString
    Nothing             -> mzero


nodeIdToUnxed :: NodeId -> String
nodeIdToUnxed (NodeId aPoint) = CB.unpack . hex . B.pack $ unroll aPoint


myTextUnhex :: T.Text -> Maybe B.ByteString
myTextUnhex aString = fromString <$> aUnxeded
    where
        aUnxeded :: Maybe String
        aUnxeded = unhex aNewString

        aNewString :: String
        aNewString = T.unpack aString


instance FromJSON PPToNNMessage where
    parseJSON (Object aMessage) = do
        aTag  :: T.Text <- aMessage .: "tag"
        aType :: T.Text <- aMessage .: "type"
        --error $ show aTag ++ " " ++ show aType
        case (T.unpack aTag, T.unpack aType) of
            ("Request", "Transaction") -> RequestTransaction <$> aMessage .: "number"

            ("Request", "Broadcast") -> do
                aMsg :: Value <- aMessage .: "msg"
                aRecipientType :: T.Text <-  aMessage .: "recipientType"
                return $ RequestBroadcast (readNodeType aRecipientType) aMsg

            ("Request","Connects")    -> do
                aFull :: Maybe T.Text <- aMessage .:? "full"
                return $ RequestConnects (isJust aFull)

            ("Request","PoWList")     -> return RequestPoWList

            ("Response", "NodeId") -> do
                aPPId :: T.Text <- aMessage .: "nodeId"

                aNodeId   <- unhexNodeId aPPId
                aNodeType :: T.Text <- aMessage .: "nodeType"
                return (ResponseNodeIdToNN aNodeId (readNodeType aNodeType))

            ("Msg", "MsgTo") -> do
                aDestination :: T.Text <- aMessage .: "destination"
                aMsg         :: Value  <- aMessage .: "msg"
                aNodeId <- unhexNodeId aDestination
                return $ MsgMsgToNN aNodeId aMsg

            ("Msg", "Microblock") ->
                MsgMicroblock <$> aMessage .: "microblock"

            -- testing functions!!!
            ("Request", "Pending") -> do
                aMaybeTransaction <- aMessage .:? "transaction"
                return $ case aMaybeTransaction of
                    Just aTransaction -> IsInPendingRequest aTransaction
                    Nothing           -> GetPendingRequest

            ("Request", "PendingAdd") ->
                AddTransactionRequest <$> aMessage .: "transaction"
            ("Action", "AddToListOfConnects") ->
                ActionAddToListOfConnects <$> aMessage .: "port"

            ("Action", "NodeStillAliveTest") -> do
                aPort        <- aMessage .: "port"
                aIp          <- aMessage .: "ip"
                case readMaybe aIp of
                    Just aJustIp -> return $ ActionNodeStillAliveTest
                        (toEnum aPort) (toHostAddress aJustIp)
                    _ -> mzero
            ("Action", "Connect") -> do
                aNodeType :: T.Text  <- aMessage .: "node_type"
                --let aType = readNodeType aNodeType
                case readNodeType aNodeType of
                    NN -> do
                        aPort       <- aMessage .: "port"
                        publicPoint <- aMessage .: "public_point"
                        aNodeId     <- unhexNodeId =<< aMessage .: "my_id"
                        return $ NNConnection (toEnum aPort) publicPoint aNodeId
                    aCN  -> do
                        aNodeId <- aMessage .:? "my_id"
                        aId <- return $ unhexNodeId =<< aNodeId
                        return $ CNConnection aCN aId
            ("Request","ActualConnectList") -> return $ RequestActualConnectList
            _ -> mzero


{-


Для СН от КН -- {"tag":"Action", "type":"Connect", "node_type": "PoW" | "PoA", "my_id": 123}
Для СН от КН -- {"tag":"Action", "type":"Connect", "node_type": "PoW" | "PoA"}
--     | NNConnection PortNumber PublicPoint NodeId
--    | CNConnection NodeType (Maybe NodeId)
-}


    parseJSON _ = mzero -- error $ show a

readNodeType :: (IsString a, Eq a) => a -> NodeType
readNodeType aNodeType
    | aNodeType == "PoW" = PoW
    | aNodeType == "PoA" = PoA
    | aNodeType == "NN"  = NN
    | otherwise          = All

decodeList :: [T.Text] -> [String]
decodeList aList
    | all isRight aDecodeList   = rights aDecodeList
    | otherwise                 = error "Can not decode all transactions in Microblock"
    where aDecodeList = myUnhex <$> aList



instance ToJSON NNToPPMessage where
    toJSON RequestNodeIdToPP = object [
        "tag"   .= ("Request" :: String),
        "type"  .= ("NodeId"  :: String)
      ]

    toJSON (MsgMsgToPP aPPId aMessage) = object [
            "tag"       .= ("Msg"   :: String),
            "type"      .= ("MsgTo" :: String),
            "sender"    .= nodeIdToUnxed aPPId,
            "msg"       .= aMessage
          ]

    toJSON (ResponseConnects aConnects) = object [
        "tag"       .= ("Response"  :: String),
        "type"      .= ("Connects"  :: String),
        "connects"  .= aConnects
      ]

    toJSON (MsgNewNodeInNet aPPId aNodeType Nothing) = object [
        "tag"       .= ("Msg"           :: String),
        "type"      .= ("NewNodeInNet"  :: String),
        "id"        .= nodeIdToUnxed aPPId,
        "nodeType"  .= show aNodeType
      ]

    toJSON (MsgNewNodeInNet aPPId aNodeType (Just aConnect)) = object [
        "tag"       .= ("Msg"           :: String),
        "type"      .= ("NewNodeInNet"  :: String),
        "id"        .= nodeIdToUnxed aPPId,
        "nodeType"  .= show aNodeType,
        "connect"   .= aConnect
      ]

    toJSON (ResponseTransaction aTransaction) = object [
        "tag"       .= ("Response"     :: String),
        "type"      .= ("Transaction"  :: String),
        "transaction" .= aTransaction
      ]

    toJSON (MsgBroadcastMsg aMessage (IdFrom aPPId)) = object [
        "tag"       .= ("Msg"           :: String),
        "type"      .= ("Broadcast"  :: String),
        "msg"       .= aMessage,
        "idFrom"    .= nodeIdToUnxed aPPId
      ]

    toJSON (ResponsePoWList aPPIds) = object [
        "tag"       .= ("Response"  :: String),
        "type"      .= ("PoWList"   :: String),
        "poWList"   .=  map nodeIdToUnxed aPPIds
      ]
    toJSON (ResponsePendingTransactions aTransactions) = object [
        "tag"       .= ("Response"  :: String),
        "type"      .= ("Pending"   :: String),
        "transactions" .= aTransactions
      ]
    toJSON (ResponseIsInPending aBool) = object [
        "tag"       .= ("Response"  :: String),
        "type"      .= ("Pending"   :: String),
        "msg"       .= show aBool
      ]
    toJSON (ResponseTransactionValid aBool) = object [
        "tag"       .= ("Response"  :: String),
        "type"      .= ("PendingAdd"   :: String),
        "msg"       .= show aBool
       ]
    toJSON (ResponseClientId aNodeId) = object [
        "tag"       .= ("Response"  :: String),
        "type"      .= ("NodeId"   :: String),
        "node_id"   .= nodeIdToUnxed aNodeId
      ]
    toJSON (ActualConnectList aConnects) = object [
        "tag"               .= ("Response"  :: String),
        "type"              .= ("ActualConnectList"   :: String),
        "actual_connects"   .= aConnects
      ]


instance ToJSON Connect where
    toJSON (Connect aHostAddress aPortNumber) = object [
        "ip"   .= show (fromHostAddress aHostAddress),
        "port" .= fromEnum aPortNumber
      ]

instance FromJSON Connect where
    parseJSON (Object aConnect) = do
        aIp     <- aConnect .: "ip"
        aPort   <- aConnect .: "port"
        case readMaybe aIp of
            Nothing      -> mzero
            Just aJustIp -> return $
                Connect (toHostAddress aJustIp) (toEnum aPort)

--------------------------------------------------------------------------------
