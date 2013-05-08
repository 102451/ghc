{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  LwConc.Schedulers.ConcurrentList
-- Copyright   :  (c) The University of Glasgow 2001
-- License     :  BSD-style (see the file libraries/base/LICENSE)
-- 
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (concurrency)
--
-- A concurrent round-robin scheduler.
--
-----------------------------------------------------------------------------


module ConcurrentList
(
  Sched
, SCont

, newSched           -- IO (Sched)
, newCapability      -- IO ()
, forkIO             -- IO () -> IO SCont
, forkOS             -- IO () -> IO SCont
, forkOn             -- Int -> IO () -> IO SCont
, yield              -- IO ()

, throwTo            -- Exception e => SCont -> e -> IO ()
, BlockedIndefinitelyOnConcDS(..)
, blockedIndefinitelyOnConcDS
) where

import LwConc.Substrate
import Data.Array.IArray
import Data.Dynamic

#include "profile.h"

-- The scheduler data structure has one (PVar [SCont], PVar [SCont]) for every
-- capability.
newtype Sched = Sched (Array Int (PVar [SCont], PVar [SCont]))

_INL_(yieldControlAction)
yieldControlAction :: Sched -> SCont -> PTM ()
yieldControlAction !(Sched pa) !sc = do
  stat <- getSContStatus sc
  unsafeIOToPTM $ debugPrint $ "yca: " ++ show sc ++ " " ++ show stat
  -- Fetch current capability's scheduler
  cc <- getCurrentCapability
  let !(frontRef, backRef)= pa ! cc
  front <- readPVar frontRef
  case front of
    [] -> do
      back <- readPVar backRef
      case reverse back of
        [] -> sleepCapability
        x:tl -> do
          writePVar frontRef tl
          writePVar backRef []
          switchTo x
    x:tl -> do
      writePVar frontRef $ tl
      switchTo x

_INL_(scheduleSContAction)
scheduleSContAction :: Sched -> SCont -> PTM ()
scheduleSContAction !(Sched pa) !sc = do
  stat <- getSContStatus sc
  unsafeIOToPTM $ debugPrint $ "ssa: " ++ show sc ++ " " ++ show stat
  -- Since we are making the given scont runnable, update its status to Yielded.
  setSContSwitchReason sc Yielded
  -- Fetch the given SCont's scheduler.
  !cap <- getSContCapability sc
  let (_,backRef) = pa ! cap
  !back <- readPVar backRef
  writePVar backRef $! sc:back

_INL_(newSched)
newSched :: IO (Sched)
newSched = do
  -- This token will be used to spawn in a round-robin fashion on different
  -- capabilities.
  token <- newPVarIO (0::Int)
  -- Save the token in the Thread-local State (TLS)
  s <- getSContIO
  setSLS s $ toDyn token
  -- Create the scheduler data structure
  nc <- getNumCapabilities
  rl <- createPVarList nc []
  let sched = Sched (listArray (0, nc-1) rl)
  -- Initialize scheduler actions
  atomically $ do {
  setYieldControlAction s $ yieldControlAction sched;
  setScheduleSContAction s $ scheduleSContAction sched
  }
  -- return scheduler
  return sched
  where
    createPVarList 0 l = return l
    createPVarList n l = do {
      frontRef <- newPVarIO [];
      backRef <- newPVarIO [];
      createPVarList (n-1) $ (frontRef,backRef):l
    }

_INL_(newCapability)
newCapability :: IO ()
newCapability = do
 -- Initial task body
 let initTask = atomically $ do {
  s <- getSCont;
  yca <- getYieldControlAction;
  setSContSwitchReason s Completed;
  yca
 }
 -- Create and initialize new task
 s <- newSCont initTask
 atomically $ do
   mySC <- getSCont
   yca <- getYieldControlActionSCont mySC
   setYieldControlAction s yca
   ssa <- getScheduleSContActionSCont mySC
   setScheduleSContAction s ssa
 scheduleSContOnFreeCap s

data SContKind = Bound | Unbound

_INL_(fork)
fork :: IO () -> Maybe Int -> SContKind -> IO SCont
fork task on kind = do
  currentSC <- getSContIO
  nc <- getNumCapabilities
  -- epilogue: Switch to next thread after completion
  let epilogue = atomically $ do {
    sc <- getSCont;
    setSContSwitchReason sc Completed;
    switchToNext <- getYieldControlAction;
    switchToNext
  }
  let makeSCont = case kind of
                    Bound -> newBoundSCont
                    Unbound -> newSCont
  newSC <- makeSCont (task >> epilogue)
  -- Initialize TLS
  tls <- atomically $ getSLS currentSC
  setSLS newSC $ tls
  let token::PVar Int = case fromDynamic tls of
                          Nothing -> error "TLS"
                          Just x -> x
  t <- atomically $ do
    mySC <- getSCont
    -- Initialize scheduler actions
    yca <- getYieldControlActionSCont mySC
    setYieldControlAction newSC yca
    ssa <- getScheduleSContActionSCont mySC
    setScheduleSContAction newSC ssa
    t <- readPVar token
    writePVar token $ (t+1) `mod` nc
    return t
  -- Set SCont Affinity
  case on of
    Nothing -> setSContCapability newSC t
    Just t' -> setSContCapability newSC $ t' `mod` nc
  -- Schedule new Scont
  atomically $ do
    ssa <- getScheduleSContActionSCont newSC
    ssa newSC
  return newSC

_INL_(forkIO)
forkIO :: IO () -> IO SCont
forkIO task = fork task Nothing Unbound

_INL_(forkOS)
forkOS :: IO () -> IO SCont
forkOS task = fork task Nothing Bound

_INL_(forkOn)
forkOn :: Int -> IO () -> IO SCont
forkOn on task = fork task (Just on) Unbound


_INL_(yield)
yield :: IO ()
yield = atomically $ do
  -- Update SCont status to Yielded
  s <- getSCont
  setSContSwitchReason s Yielded
  -- Append current SCont to scheduler
  append <- getScheduleSContAction
  append
  -- Switch to next SCont from Scheduler
  switchToNext <- getYieldControlAction
  switchToNext
