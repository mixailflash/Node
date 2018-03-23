{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ViewPatterns #-}
module Sharding.Sharding where

import              Sharding.Space.Distance
import              Sharding.Space.Points
import              Sharding.Space.Shift
import              Sharding.Types

import              Node.Node.Types
import              Control.Concurrent.Chan
import              Data.List.Extra
import              Control.Concurrent
import              Lens.Micro
import              Control.Monad
import qualified    Data.ByteString     as B
import              Data.Word
import              Node.Data.Data
import              Service.Timer
import qualified    Data.Set            as S


-- TODO Is it file or db like sqlite?
-- TODO What am I do if my neighbors is a liars?
loadMyBlockIndex :: IO (S.Set BlockHash)
loadMyBlockIndex = undefined

-- TODO Is it file or db like sqlite?
loadInitInformation :: IO (S.Set Neighbor, MyNodePosition)
loadInitInformation = undefined


sendToNetLevet :: Chan ManagerMiningMsgBase -> ShardingNodeRequestAndResponce -> IO ()
sendToNetLevet aChan aMsg = writeChan aChan $ ShardingNodeRequestOrResponce aMsg

initOfShardingNode aChanOfNetLevel aChanRequest aMyNodeId aMyNodePosition = do
    sendToNetLevet aChanOfNetLevel $ IamAwakeRequst aMyNodeId aMyNodePosition

    aMyBlocksIndex <- loadMyBlockIndex
    (aMyNeighbors, aMyPosition) <- loadInitInformation

    metronome (10^8) $ do
        writeChan aChanRequest CleanBlocksAction
        writeChan aChanRequest ShiftAction

    return $ makeEmptyShardingNode aMyNeighbors aMyNodeId aMyPosition aMyBlocksIndex


neighborPositions :: ShardingNode -> S.Set NodePosition
neighborPositions = S.map (^.neighborPosition) . (^.nodeNeighbors)

shiftIsNeed :: ShardingNode -> Bool
shiftIsNeed aShardingNode = checkUnevenness
    (aShardingNode^.nodePosition) (neighborPositions aShardingNode)


shiftTheShardingNode ::
        Chan ManagerMiningMsgBase
    -> (ShardingNode ->  IO ())
    ->  ShardingNode
    ->  IO ()
shiftTheShardingNode aChanOfNetLevel aLoop aShardingNode = do
    let
        aNeighborPositions :: S.Set NodePosition
        aNeighborPositions = neighborPositions aShardingNode

        aMyNodePosition :: MyNodePosition
        aMyNodePosition    = aShardingNode^.nodePosition

        aNearestPositions :: S.Set NodePosition
        aNearestPositions  = S.fromList $
            findNearestNeighborPositions aMyNodePosition aNeighborPositions

        aNewPosition :: MyNodePosition
        aNewPosition       = shiftToCenterOfMass aMyNodePosition aNearestPositions

    sendToNetLevet aChanOfNetLevel $ NewPosiotionResponse aNewPosition
    aLoop $ aShardingNode & nodePosition .~ aNewPosition


deleteTheNeighbor :: NodeId -> ShardingNode -> ShardingNode
deleteTheNeighbor aNodeId aShardingNode =
    aShardingNode & nodeNeighbors %~ S.filter (\n -> n^.neighborId /= aNodeId)


insertTheNeighbor :: NodeId -> NodePosition -> ShardingNode -> ShardingNode
insertTheNeighbor aNodeId aNodePosition aShardingNode =
    aShardingNode & nodeNeighbors %~ S.insert (Neighbor aNodePosition aNodeId)


findShardingNodeDomain :: ShardingNode -> Distance Point
findShardingNodeDomain aShardingNode = findNodeDomain
    (aShardingNode^.nodePosition)
    (neighborPositions aShardingNode)


isInNodeDomain :: ShardingNode -> NodePosition -> Bool
isInNodeDomain aShardingNode aNodePosition =
    distanceTo (aShardingNode^.nodePosition) aNodePosition `div` neighborsDistanseMemoryConstant < findShardingNodeDomain aShardingNode


--makeShardingNode :: MyNodeId -> Point -> IO ()
makeShardingNode aMyNodeId  aChanRequest aChanOfNetLevel aMyNodePosition= do
    aShardingNode <- initOfShardingNode aChanOfNetLevel aChanRequest aMyNodeId aMyNodePosition
    void $ forkIO $ aLoop aShardingNode
  where
    aLoop :: ShardingNode -> IO ()
    aLoop aShardingNode = readChan aChanRequest >>= \case
        ShiftAction | shiftIsNeed aShardingNode ->
            shiftTheShardingNode aChanOfNetLevel aLoop aShardingNode

        TheNodeHaveNewCoordinates aNodeId aNodePosition
            | isInNodeDomain aShardingNode aNodePosition -> aLoop
                $ insertTheNeighbor aNodeId aNodePosition
                $ deleteTheNeighbor aNodeId aShardingNode
            | otherwise -> aLoop
                $ deleteTheNeighbor aNodeId aShardingNode

        TheNodeIsDead aNodeId -> aLoop
            $ deleteTheNeighbor aNodeId aShardingNode

        NewNodeInNetAction aNodeId aNodePosition -> aLoop
            $ insertTheNeighbor aNodeId aNodePosition aShardingNode

        _ -> undefined
{-
|   NewNodeInNetAction          NodeId Point
-- TODO create index for new node by NodeId
|   BlockIndexCreateAction      NodeId
|   BlockIndexAcceptAction      [BlockHash]
|   BlocksAcceptAction          [(BlockHash, Block)]
---
|   CleanBlocksAction -- clean local blocks
--- ShiftAction => NewPosiotionResponse
|   NewBlockInNetAction         BlockHash Block
|   ShiftAction                                                     -- [+]
|   TheNodeHaveNewCoordinates   NodeId NodePosition
---- NeighborListRequest => NeighborListAcceptAction
|   NeighborListAcceptAction   [(NodeId, NodePosition)]
|   TheNodeIsDead               NodeId

-}
--------------------------------------------------------------------------------

--------------------------TODO-TO-REMOVE-------------------------------------------
findNodeDomain :: MyNodePosition -> S.Set NodePosition -> Distance Point
findNodeDomain aMyPosition aPositions = if
    | length aNearestPoints < 4 -> maxBound
    | otherwise                 ->
        last . sort $ distanceTo aMyPosition <$> aNearestPoints
  where
    aNearestPoints = findNearestNeighborPositions aMyPosition aPositions
