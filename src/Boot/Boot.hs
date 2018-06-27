{-# LANGUAGE ViewPatterns, MultiParamTypeClasses #-}
module Boot.Boot (managerBootNode) where

import qualified    Data.Map                        as M
import qualified    Data.Set                        as S
import              Data.List
import              Data.IORef
import              Control.Monad.Extra
import              Lens.Micro
import              Control.Concurrent.Chan.Unagi.Bounded
import              Data.Maybe

import              Boot.Types
import              Node.Node.Base
import              Node.Node.Types
import              Service.Monad.Option
import              Node.Data.Key

import              Node.Data.NetPackage
import              Node.Data.GlobalLoging
import              Service.InfoMsg
import              Service.Network.Base
import              Node.FileDB.FileServer

managerBootNode :: (InChan ManagerBootNodeMsgBase, OutChan ManagerBootNodeMsgBase) -> IORef NodeBootNodeData -> IO ()
managerBootNode (ch, outCh) md = forever $ do
    mData <- readIORef md
    aMsg <- readChan outCh
    runOption aMsg $ do
        baseNodeOpts ch md mData

        opt isClientIsDisconnected $ bootNodeAnswerClientIsDisconnected md

        opt isInitDatagram        $ answerToInitDatagram md
        opt isDatagramMsg         $ answerToDatagramMsg ch md (mData^.myNodeId)
        opt isCheckBroadcastNodes $ answerToCheckBroadcastNodes md ch
        opt isCheckBroadcastNode  $ answerToCheckBroadcastNode ch md


answerToCheckBroadcastNodes
    ::  IORef NodeBootNodeData
    ->  InChan ManagerBootNodeMsgBase
    ->  ManagerBootNodeMsgBase
    ->  IO ()
answerToCheckBroadcastNodes aMd aChan _ = do
    aData <- readIORef aMd
    writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag, RegularTag] Info
        "Checking of bradcasts"
    let
        -- active nodes.
        aNodeIds :: [NodeId]
        aNodeIds = do
            (aId, aNode) <- M.toList $ aData^.nodes
            guard $ aNode^.status == Active
            pure aId

        (aBroadcastNodes, aNeededInBroadcastList) = partition
            (\aId -> S.notMember aId $ aData^.checSet) aNodeIds

    forM_ aNeededInBroadcastList $ \aNodeId -> do
        writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag, RegularTag] Info $
            "Start of node check " ++ show aNodeId ++ ". Is it broadcast?"
        whenJust (aData^.nodes.at aNodeId) $ \aNode -> do
            sendExitMsgToNode aNode
            writeChan aChan $ checkBroadcastNode
                aNodeId (aNode^.nodeHost) (aNode^.nodePort)

    forM_ aBroadcastNodes $ \aNodeId -> do
        writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag, RegularTag] Info $
            "Ending of node check " ++ show aNodeId ++ ". Is it broadcast?"
        modifyIORef aMd $ checSet %~ S.delete aNodeId

        let aMaybeNode = aData^.nodes.at aNodeId
        when (isNothing aMaybeNode) $
            writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag, RegularTag] Info $
                "The node " ++ show aNodeId ++ " doesn't a broadcast."

        whenJust aMaybeNode $ \aNode -> do
            writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag, RegularTag] Info $
                "The node " ++ show aNodeId ++ " is broadcast."
            writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag, RegularTag] Info
                "Addition the node to list of broadcast node."
            sendExitMsgToNode aNode

            writeChan (aData^.fileServerChan) $
                    FileActorRequestNetLvl $ UpdateFile (aData^.myNodeId)
                    (NodeInfoListNetLvl [(aNodeId, Connect (aNode^.nodeHost) (aNode^.nodePort))])


answerToCheckBroadcastNode :: ManagerMsg a =>
    InChan a -> IORef NodeBootNodeData -> ManagerBootNodeMsgBase -> IO ()
answerToCheckBroadcastNode aChan aMd (CheckBroadcastNode aNodeId aIp aPort) = do
    aData <- readIORef aMd
    writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag] Info $
        "Check of node " ++ show aNodeId ++ " " ++ show aIp ++ ":" ++
        show aPort ++ ". Is it broadcast?"
    modifyIORef aMd $ checSet %~ S.insert aNodeId
    writeChan aChan $ sendInitDatagram aIp aPort aNodeId
answerToCheckBroadcastNode _ _ _ = return ()


bootNodeAnswerClientIsDisconnected ::
    IORef NodeBootNodeData -> ManagerBootNodeMsgBase -> IO ()
bootNodeAnswerClientIsDisconnected aMd
    (toManagerMsg -> ClientIsDisconnected aId aChan) = do
        aData <- readIORef aMd
        whenJust (aId `M.lookup` (aData^.nodes)) $ \aNode ->
            when (aNode^.chan == aChan) $ do
                writeLog (aData^.infoMsgChan) [BootNodeTag, NetLvlTag] Info $
                    "The node " ++ show aId ++ " is disconnected."
                modifyIORef aMd (nodes %~ M.delete aId)
bootNodeAnswerClientIsDisconnected _ _ = pure ()
