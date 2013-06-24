{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Service.Registry
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The module provides an extended process registry, offering slightly altered
-- semantics to the built in @register@ and @unregister@ primitives and a richer
-- set of features:
--
-- * Associate (unique) keys with a process /or/ (unique keys per-process) values
-- * Use any 'Keyable' algebraic data type (beside 'String') as a key/name
-- * Query for process with matching keys / values / properties
-- * Atomically /give away/ properties or names
-- * Forceibly re-allocate names from a third party
--
-- [Subscribing To Registry Events]
--
-- It is possible to monitor a registry for changes and be informed whenever
-- changes take place. All subscriptions are /key based/, which means that
-- you can subscribe to name or property changes for any process, though any
-- property changes matching the key you've subscribed to will trigger a
-- notification (i.e., regardless of the process to which the property belongs).
--
-- The different events are defined by the 'KeyUpdateEvent' type.
--
-- Processes subscribe to registry events using @monitorName@ or its counterpart
-- @monitorProperty@. If the operation succeeds, this will evaluate to an
-- opaque /reference/ which can be used in subsequently handling any received
-- notifications, which will be delivered to the subscriber's mailbox as
-- @RegistryKeyMonitorNotification keyIdentity opaqueRef event@, where @event@
-- has the type 'KeyUpdateEvent'.
--
-- Subscribers can filter the types of event they receive by using the lower
-- level @monitor@ function (defined in /this/ module - not the one defined
-- in distributed-process' Primitives) and passing a list of
-- 'KeyUpdateEventMask'. Without these filters in place, a monitor event will
-- be fired for /every/ pertinent change.
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Platform.Service.Registry
  ( -- * Registry Keys
    KeyType(..)
  , Key(..)
  , Keyable
    -- * Defining / Starting A Registry
  , Registry(..)
  , start
  , run
    -- * Registration / Unregistration
  , addName
  , addProperty
  , registerName
  , registerValue
  , RegisterKeyReply(..)
  , unregisterName
  , UnregisterKeyReply(..)
    -- * Queries / Lookups
  , lookupName
  , registeredNames
  , foldNames
    -- * Monitoring / Waiting
  , monitor
  , monitorName
  , await
  , awaitTimeout
  , AwaitResult(..)
  , KeyUpdateEventMask(..)
  , KeyUpdateEvent(..)
  , RegKeyMonitorRef
  , RegistryKeyMonitorNotification(RegistryKeyMonitorNotification)
  ) where

{- DESIGN NOTES
This registry is a single process, parameterised by the types of key and
property value it can manage. It is, of course, possible to start multiple
registries and inter-connect them via registration (or whatever mean) with
one another.

The /Service/ API is intended to be a declarative layer in which you define
the managed processes that make up your services, and each /Service Component/
is registered and supervised appropriately for you, with the correct restart
strategies and start order calculated and so on. The registry is not only a
service locator, but provides the /wait for these dependencies to start first/
bit of the puzzle.

At some point, I'd like to offer a shared memory based registry, created on
behalf of a particular subsystem (i.e., some service or service group) and
passed implicitly using a reader monad or some such. This would allow multiple
processes to interact with the registry using STM (or perhaps a simple RWLock)
and could facilitate reduced contention.

Even for the singleton-process based registry (i.e., this one) we /might/ also
be better off separating the monitoring (or at least the notifications) from
the registration/mapping parts into separate processes.
-}

import Control.Distributed.Process hiding (call, monitor, unmonitor, mask)
import qualified Control.Distributed.Process as P (monitor)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Internal.Primitives hiding (monitor)
import qualified Control.Distributed.Process.Platform.Internal.Primitives as PL
  ( monitor
  )
import Control.Distributed.Process.Platform.Internal.SerializableHashMap
  ( SHashMap(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess
  ( call
  , cast
  , handleInfo
  , reply
  , continue
  , input
  , defaultProcess
  , prioritised
  , InitHandler
  , InitResult(..)
  , ProcessAction
  , ProcessReply
  , ProcessDefinition(..)
  , PrioritisedProcessDefinition(..)
  , DispatchPriority
  , CallRef
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
  ( pserve
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server
  ( handleCallIf
  , handleCallFrom
  , handleCast
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
  ( prioritiseInfo_
  , setPriority
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted
  ( RestrictedProcess
  , Result
  , getState
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( handleCall
  , reply
  )
-- import Control.Distributed.Process.Platform.ManagedProcess.Server.Unsafe
-- import Control.Distributed.Process.Platform.ManagedProcess.Server
import Control.Distributed.Process.Platform.Time
import Control.Monad (forM_)
import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (^=)
  , (^.)
  )
import Data.Binary
import Data.Foldable hiding (elem, forM_)
import Data.Maybe (fromJust, isJust)
import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import Data.HashSet (HashSet)
import qualified Data.HashSet as Set
import Data.Typeable (Typeable)

import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- | Describes how a key will be used - for storing names or properties.
data KeyType =
    KeyTypeAlias    -- ^ the key will refer to a name (i.e., named process)
  | KeyTypeProperty -- ^ the key will refer to a (per-process) property
  deriving (Typeable, Generic, Show, Eq)
instance Binary KeyType where
instance Hashable KeyType where

-- | A registered key. Keys can be mapped to names or (process-local) properties
-- in the registry. The 'keyIdentity' holds the key's value (e.g., a string or
-- similar simple data type, which must provide a 'Keyable' instance), whilst
-- the 'keyType' and 'keyScope' describe the key's intended use and ownership.
data Key a =
    Key
    { keyIdentity :: !a
    , keyType     :: !KeyType
    , keyScope    :: !(Maybe ProcessId)
    }
  deriving (Typeable, Generic, Show, Eq)
instance (Serializable a) => Binary (Key a) where
instance (Hashable a) => Hashable (Key a) where

-- | The 'Keyable' type class describes types that can be used as registry keys.
-- The constraints ensure that the key can be stored and compared appropriately.
class (Show a, Eq a, Hashable a, Serializable a) => Keyable a
instance (Show a, Eq a, Hashable a, Serializable a) => Keyable a

-- | Used to describe a subset of monitoring events to listen for.
data KeyUpdateEventMask =
    OnKeyRegistered      -- ^ receive an event when a key is registered
  | OnKeyUnregistered    -- ^ receive an event when a key is unregistered
  | OnKeyOwnershipChange -- ^ receive an event when a key's owner changes
  | OnKeyLeaseExpiry     -- ^ receive an event when a key's lease expires
  deriving (Typeable, Generic, Eq, Show)
instance Binary KeyUpdateEventMask where

-- | An opaque reference used for matching monitoring events. See
-- 'RegistryKeyMonitorNotification' for more details.
newtype RegKeyMonitorRef =
  RegKeyMonitorRef { unRef :: (ProcessId, Integer) }
  deriving (Typeable, Generic, Eq, Show)
instance Binary RegKeyMonitorRef where
instance Hashable RegKeyMonitorRef where

instance Addressable RegKeyMonitorRef where
  resolve = return . Just . fst . unRef

-- | Provides information about a key monitoring event.
data KeyUpdateEvent =
    KeyRegistered
    {
      owner :: !ProcessId
    }
  | KeyUnregistered
  | KeyLeaseExpired
  | KeyOwnerDied
    {
      diedReason :: !DiedReason
    }
  | KeyOwnerChanged
    {
      previousOwner :: !ProcessId
    , newOwner      :: !ProcessId
    }
  deriving (Typeable, Generic, Eq, Show)
instance Binary KeyUpdateEvent where

-- | This message is delivered to processes which are monioring a
-- registry key. The opaque monitor reference will match (i.e., be equal
-- to) the reference returned from the @monitor@ function, which the
-- 'KeyUpdateEvent' describes the change that took place.
data RegistryKeyMonitorNotification k =
  RegistryKeyMonitorNotification !k !RegKeyMonitorRef !KeyUpdateEvent
  deriving (Typeable, Generic)
instance (Keyable k) => Binary (RegistryKeyMonitorNotification k) where
deriving instance (Keyable k) => Eq (RegistryKeyMonitorNotification k)
deriving instance (Keyable k) => Show (RegistryKeyMonitorNotification k)

data RegisterKeyReq k = RegisterKeyReq !(Key k)
  deriving (Typeable, Generic)
instance (Serializable k) => Binary (RegisterKeyReq k) where

-- | The (return) value of an attempted registration.
data RegisterKeyReply =
    RegisteredOk      -- ^ The given key was registered successfully
  | AlreadyRegistered -- ^ The key was already registered
  deriving (Typeable, Generic, Eq, Show)
instance Binary RegisterKeyReply where

data LookupKeyReq k = LookupKeyReq !(Key k)
  deriving (Typeable, Generic)
instance (Serializable k) => Binary (LookupKeyReq k) where

data RegNamesReq = RegNamesReq !ProcessId
  deriving (Typeable, Generic)
instance Binary RegNamesReq where

data UnregisterKeyReq k = UnregisterKeyReq !(Key k)
  deriving (Typeable, Generic)
instance (Serializable k) => Binary (UnregisterKeyReq k) where

-- | The result of an un-registration attempt.
data UnregisterKeyReply =
    UnregisterOk  -- ^ The given key was successfully unregistered
  | UnregisterInvalidKey -- ^ The given key was invalid and could not be unregistered
  | UnregisterKeyNotFound -- ^ The given key was not found (i.e., was not registered)
  deriving (Typeable, Generic, Eq, Show)
instance Binary UnregisterKeyReply where

data MonitorReq k = MonitorReq !(Key k) !(Maybe [KeyUpdateEventMask])
  deriving (Typeable, Generic)
instance (Keyable k) => Binary (MonitorReq k) where

-- | The result of an @await@ operation.
data AwaitResult k =
    RegisteredName     !ProcessId !k   -- ^ The name was registered
  | ServerUnreachable  !DiedReason     -- ^ The server was unreachable (or died)
  | AwaitTimeout                       -- ^ The operation timed out
  deriving (Typeable, Generic, Eq, Show)
instance (Keyable k) => Binary (AwaitResult k) where

-- | A phantom type, used to parameterise registry startup
-- with the required key and value types.
data Registry k v = Registry

data KMRef = KMRef { ref  :: !RegKeyMonitorRef
                   , mask :: !(Maybe [KeyUpdateEventMask])
                     -- use Nothing to monitor every event
                   }
  deriving (Show)

data State k v =
  State
  {
    _names          :: !(HashMap k ProcessId)
  , _properties     :: !(HashMap (ProcessId, k) v)
  , _monitors       :: !(HashMap k KMRef)
  , _registeredPids :: !(HashSet ProcessId)
  , _listeningPids  :: !(HashSet ProcessId)
  , _monitorIdCount :: !Integer
  , _registryType   :: !(Registry k v)
  }
  deriving (Typeable, Generic)

--------------------------------------------------------------------------------
-- Starting / Running A Registry                                              --
--------------------------------------------------------------------------------

start :: forall k v. (Keyable k, Serializable v)
      => Registry k v
      -> Process ProcessId
start reg = spawnLocal $ run reg

run :: forall k v. (Keyable k, Serializable v)
    => Registry k v
    -> Process ()
run reg = MP.pserve () (initIt reg) serverDefinition

initIt :: forall k v. (Keyable k, Serializable v)
       => Registry k v
       -> InitHandler () (State k v)
initIt reg () = return $ InitOk initState Infinity
  where
    initState = State { _names          = Map.empty
                      , _properties     = Map.empty
                      , _monitors       = Map.empty
                      , _registeredPids = Set.empty
                      , _listeningPids  = Set.empty
                      , _monitorIdCount = (1 :: Integer)
                      , _registryType   = reg
                      } :: State k v

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

-- | Associate the current process with the given (unique) key.
addName :: (Addressable a, Keyable k) => a -> k -> Process RegisterKeyReply
addName s n = getSelfPid >>= registerName s n

-- | Associate the given (non-unique) property with the current process.
addProperty :: (Serializable a, Keyable k, Serializable v)
            => a -> Key k -> v -> Process ()
addProperty = undefined

-- | Register the item at the given address.
registerName :: (Addressable a, Keyable k)
             => a -> k -> ProcessId -> Process RegisterKeyReply
registerName s n p = call s $ RegisterKeyReq (Key n KeyTypeAlias $ Just p)

-- | Register an item at the given address and associate it with a value.
registerValue :: (Addressable a, Keyable k, Serializable v)
              => a -> k -> v -> Process ()
registerValue = undefined

unregisterName :: (Addressable a, Keyable k)
               => a
               -> k
               -> Process UnregisterKeyReply
unregisterName s n = do
  self <- getSelfPid
  call s $ UnregisterKeyReq (Key n KeyTypeAlias $ Just self)

lookupName :: (Addressable a, Keyable k) => a -> k -> Process (Maybe ProcessId)
lookupName s n = call s $ LookupKeyReq (Key n KeyTypeAlias Nothing)

registeredNames :: (Addressable a, Keyable k) => a -> ProcessId -> Process [k]
registeredNames s p = call s $ RegNamesReq p

monitorName :: (Addressable a, Keyable k)
            => a -> k -> Process RegKeyMonitorRef
monitorName svr name = do
  let key' = Key { keyIdentity = name
                 , keyScope    = Nothing
                 , keyType     = KeyTypeAlias
                 }
  monitor svr key' Nothing

monitor :: (Addressable a, Keyable k)
        => a
        -> Key k
        -> Maybe [KeyUpdateEventMask]
        -> Process RegKeyMonitorRef
monitor svr key' mask' = call svr $ MonitorReq key' mask'

await :: (Addressable a, Keyable k)
      => a
      -> k
      -> Process (AwaitResult k)
await a k = awaitTimeout a Infinity k

awaitTimeout :: (Addressable a, Keyable k)
             => a
             -> Delay
             -> k
             -> Process (AwaitResult k)
awaitTimeout a d k = do
    p <- forceResolve a
    Just mRef <- PL.monitor p
    kRef <- monitor a (Key k KeyTypeAlias Nothing) (Just [OnKeyRegistered])
    let matches' = matches mRef kRef k
    let recv = case d of
                 Infinity -> receiveWait matches' >>= return . Just
                 Delay t  -> receiveTimeout (asTimeout t) matches'
    recv >>= return . maybe AwaitTimeout id
  where
    forceResolve addr = do
      mPid <- resolve addr
      case mPid of
        Nothing -> die "InvalidAddressable"
        Just p  -> return p

    matches mr kr k' = [
        matchIf (\(RegistryKeyMonitorNotification mk' kRef' ev') ->
                      (matchEv ev' && kRef' == kr && mk' == k'))
                (\(RegistryKeyMonitorNotification _ _ (KeyRegistered pid)) ->
                  return $ RegisteredName pid k')
      , matchIf (\(ProcessMonitorNotification mRef' _ _) -> mRef' == mr)
                (\(ProcessMonitorNotification _ _ dr) ->
                  return $ ServerUnreachable dr)
      ]

    matchEv ev' = case ev' of
                    KeyRegistered _ -> True
                    _               -> False

data QueryDirect = QueryDirectNames | QueryDirectProperties
  deriving (Typeable, Generic)
instance Binary QueryDirect where

foldNames :: forall a b k. (Addressable a, Keyable k)
          => a
          -> b
          -> (b -> (k, ProcessId) -> Process b)
          -> Process b
foldNames addr acc fn = do
  self <- getSelfPid
  cast addr $ (self, QueryDirectNames)
  SHashMap _ m <- expect :: Process (SHashMap k ProcessId)
  foldlM fn acc (Map.toList m)

--------------------------------------------------------------------------------
-- Server Process                                                             --
--------------------------------------------------------------------------------

serverDefinition :: forall k v. (Keyable k, Serializable v)
                 => PrioritisedProcessDefinition (State k v)
serverDefinition = prioritised processDefinition regPriorities
  where
    regPriorities :: [DispatchPriority (State k v)]
    regPriorities = [
        prioritiseInfo_ (\(ProcessMonitorNotification _ _ _) -> setPriority 100)
      ]

processDefinition :: forall k v. (Keyable k, Serializable v)
                  => ProcessDefinition (State k v)
processDefinition =
  defaultProcess
  {
    apiHandlers =
       [
         handleCallIf
              (input ((\(RegisterKeyReq (Key{..} :: Key k)) ->
                        keyType == KeyTypeAlias && (isJust keyScope))))
              handleRegisterName
       , handleCallIf
              (input ((\(LookupKeyReq (Key{..} :: Key k)) ->
                        keyType == KeyTypeAlias)))
              (\state (LookupKeyReq key') -> reply (findName key' state) state)
       , handleCallIf
              (input ((\(UnregisterKeyReq (Key{..} :: Key k)) ->
                        keyType == KeyTypeAlias && (isJust keyScope))))
              handleUnregisterName
       , handleCallFrom handleMonitorReq
       , Restricted.handleCall handleRegNamesLookup
       , handleCast handleQuery
       ]
  , infoHandlers = [handleInfo handleMonitorSignal]
  } :: ProcessDefinition (State k v)

handleQuery :: forall k v. (Keyable k, Serializable v)
            => State k v
            -> (ProcessId, QueryDirect)
            -> Process (ProcessAction (State k v))
handleQuery st@State{..} (pid, qd) = do
  let qdH = case qd of
              QueryDirectNames -> SHashMap [] (st ^. names)
              QueryDirectProperties -> error "whoops"
  send pid qdH
  continue st

handleRegisterName :: forall k v. (Keyable k, Serializable v)
                   => State k v
                   -> RegisterKeyReq k
                   -> Process (ProcessReply RegisterKeyReply (State k v))
handleRegisterName state (RegisterKeyReq Key{..}) = do
  let found = Map.lookup keyIdentity (state ^. names)
  case found of
    Nothing -> do
      let pid  = fromJust keyScope
      let refs = state ^. registeredPids
      refs' <- ensureMonitored pid refs
      notifySubscribers keyIdentity state (KeyRegistered pid)
      reply RegisteredOk $ ( (names ^: Map.insert keyIdentity pid)
                           . (registeredPids ^= refs')
                           $ state)
    Just pid ->
      if (pid == (fromJust keyScope))
         then reply RegisteredOk      state
         else reply AlreadyRegistered state

handleUnregisterName :: forall k v. (Keyable k, Serializable v)
                     => State k v
                     -> UnregisterKeyReq k
                     -> Process (ProcessReply UnregisterKeyReply (State k v))
handleUnregisterName state (UnregisterKeyReq Key{..}) = do
  let entry = Map.lookup keyIdentity (state ^. names)
  case entry of
    Nothing  -> reply UnregisterKeyNotFound state
    Just pid ->
      case (pid /= (fromJust keyScope)) of
        True  -> reply UnregisterInvalidKey state
        False -> do
          notifySubscribers keyIdentity state KeyUnregistered
          let state' = ( (names ^: Map.delete keyIdentity)
                       . (monitors ^: Map.filterWithKey (\k' _ -> k' /= keyIdentity))
                       $ state)
          reply UnregisterOk $ state'

handleMonitorReq :: forall k v. (Keyable k, Serializable v)
                 => State k v
                 -> CallRef RegKeyMonitorRef
                 -> MonitorReq k
                 -> Process (ProcessReply RegKeyMonitorRef (State k v))
handleMonitorReq state cRef (MonitorReq Key{..} mask') = do
  let mRefId = (state ^. monitorIdCount) + 1
  Just caller <- resolve cRef
  let mRef  = RegKeyMonitorRef (caller, mRefId)
  let kmRef = KMRef mRef mask'
  let refs = state ^. listeningPids
  refs' <- ensureMonitored caller refs
  fireEventForPreRegisteredKey state keyIdentity keyScope kmRef
  reply mRef $ ( (monitors ^: Map.insert keyIdentity kmRef)
               . (listeningPids ^= refs')
               . (monitorIdCount ^= mRefId)
               $ state
               )
  where
    fireEventForPreRegisteredKey st kId kScope KMRef{..} = do
      let evMask = maybe [] id mask
      case (keyType, elem OnKeyRegistered evMask) of
        (KeyTypeAlias, True) -> do
          let found = Map.lookup kId (st ^. names)
          fireEvent found kId ref
        (KeyTypeProperty, True) -> do
          self <- getSelfPid
          let scope = maybe self id kScope
          let found = Map.lookup (scope, kId) (st ^. properties)
          case found of
            Nothing -> return ()
            Just _  -> fireEvent (Just scope) kId ref
        _ -> return ()

    fireEvent fnd kId' ref' = do
      case fnd of
        Nothing -> return ()
        Just p  -> sendTo ref' $ (RegistryKeyMonitorNotification kId'
                                    ref'
                                    (KeyRegistered p))

handleRegNamesLookup :: forall k v. (Keyable k, Serializable v)
                     => RegNamesReq
                     -> RestrictedProcess (State k v) (Result [k])
handleRegNamesLookup (RegNamesReq p) = do
  state <- getState
  Restricted.reply $ Map.foldlWithKey' (acc p) [] (state ^. names)
  where
    acc pid ns n pid'
      | pid == pid' = (n:ns)
      | otherwise   = ns

handleMonitorSignal :: forall k v. (Keyable k, Serializable v)
                    => State k v
                    -> ProcessMonitorNotification
                    -> Process (ProcessAction (State k v))
handleMonitorSignal state@State{..} (ProcessMonitorNotification _ pid reason) =
  do let state' = removeActiveSubscriptions pid state
     (deadNames, deadProps) <- notifyListeners state' pid reason
     continue $ ( (names ^= Map.difference _names deadNames)
                . (properties ^= Map.difference _properties deadProps)
                $ state)
  where
    removeActiveSubscriptions p s =
      let subscriptions = (state ^. listeningPids) in
      case (Set.member p subscriptions) of
        False -> s
        True  -> ( (listeningPids ^: Set.delete p)
                   -- delete any monitors this (now dead) process held
                 . (monitors ^: Map.filter ((/= p) . fst . unRef . ref))
                 $ s)

    notifyListeners :: State k v
                    -> ProcessId
                    -> DiedReason
                    -> Process (HashMap k ProcessId, HashMap (ProcessId, k) v)
    notifyListeners st pid' dr = do
      let diedNames = Map.filter (== pid') (st ^. names)
      let diedProps = Map.filterWithKey (\(p, _) _ -> p == pid')
                                        (st ^. properties)
      let nameSubs  = Map.filterWithKey (\k _ -> Map.member k diedNames)
                                        (st ^. monitors)
      let propSubs  = Map.filterWithKey (\k _ -> Map.member (pid', k) diedProps)
                                        (st ^. monitors)
      forM_ (Map.toList nameSubs) $ \(kIdent, KMRef{..}) -> do
        let kEvDied = KeyOwnerDied { diedReason = dr }
        let mRef    = RegistryKeyMonitorNotification kIdent ref
        case mask of
          Nothing    -> sendTo ref (mRef kEvDied)
          Just mask' -> do
            case (elem OnKeyOwnershipChange mask') of
              True  -> sendTo ref (mRef kEvDied)
              False -> do
                if (elem OnKeyUnregistered mask')
                  then sendTo ref (mRef KeyUnregistered)
                  else return ()
      forM_ (Map.toList propSubs) (notifyPropSubscribers dr)
      return (diedNames, diedProps)

    notifyPropSubscribers dr' (kIdent, KMRef{..}) = do
      let died  = maybe False (elem OnKeyOwnershipChange) mask
      let event = case died of
                    True  -> KeyOwnerDied { diedReason = dr' }
                    False -> KeyUnregistered
      sendTo ref $ RegistryKeyMonitorNotification kIdent ref event

ensureMonitored :: ProcessId -> HashSet ProcessId -> Process (HashSet ProcessId)
ensureMonitored pid refs = do
  case (Set.member pid refs) of
    True  -> return refs
    False -> P.monitor pid >> return (Set.insert pid refs)

notifySubscribers :: forall k v. (Keyable k, Serializable v)
                  => k
                  -> State k v
                  -> KeyUpdateEvent
                  -> Process ()
notifySubscribers k st ev = do
  let subscribers = Map.filterWithKey (\k' _ -> k' == k) (st ^. monitors)
  forM_ (Map.toList subscribers) $ \(_, KMRef{..}) -> do
    if (maybe True (elem (maskFor ev)) mask)
      then sendTo ref $ RegistryKeyMonitorNotification k ref ev
      else return ()

--------------------------------------------------------------------------------
-- Utilities / Accessors                                                      --
--------------------------------------------------------------------------------

maskFor :: KeyUpdateEvent -> KeyUpdateEventMask
maskFor (KeyRegistered _)     = OnKeyRegistered
maskFor KeyUnregistered       = OnKeyUnregistered
maskFor (KeyOwnerDied   _)    = OnKeyOwnershipChange
maskFor (KeyOwnerChanged _ _) = OnKeyOwnershipChange
maskFor KeyLeaseExpired       = OnKeyLeaseExpiry

findName :: forall k v. (Keyable k, Serializable v)
         => Key k
         -> State k v
         -> Maybe ProcessId
findName Key{..} state = Map.lookup keyIdentity (state ^. names)

names :: forall k v. Accessor (State k v) (HashMap k ProcessId)
names = accessor _names (\n' st -> st { _names = n' })

properties :: forall k v. Accessor (State k v) (HashMap (ProcessId, k) v)
properties = accessor _properties (\ps st -> st { _properties = ps })

monitors :: forall k v. Accessor (State k v) (HashMap k KMRef)
monitors = accessor _monitors (\ms st -> st { _monitors = ms })

registeredPids :: forall k v. Accessor (State k v) (HashSet ProcessId)
registeredPids = accessor _registeredPids (\mp st -> st { _registeredPids = mp })

listeningPids :: forall k v. Accessor (State k v) (HashSet ProcessId)
listeningPids = accessor _listeningPids (\lp st -> st { _listeningPids = lp })

monitorIdCount :: forall k v. Accessor (State k v) Integer
monitorIdCount = accessor _monitorIdCount (\i st -> st { _monitorIdCount = i })

