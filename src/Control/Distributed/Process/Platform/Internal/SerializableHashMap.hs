{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Distributed.Process.Platform.Internal.SerializableHashMap where

import Data.HashMap.Strict (HashMap, toList, fromList)
import Data.Typeable (Typeable)
import Data.Binary (Binary(put, get), Get)
-- import Control.DeepSeq (NFData(..))
import Control.Applicative (Applicative, Alternative, (<$>), (<*>))
import Control.Distributed.Process.Serializable
  ( Serializable
  )
import Data.Hashable
import GHC.Generics

data SHashMap k v = SHashMap [(k, v)] (HashMap k v)
  deriving (Typeable, Generic)
-- instance (NFData k, NFData v) => NFData (SHashMap k v) where

instance (Eq k, Hashable k, Serializable k, Serializable v) =>
         Binary (SHashMap k v) where
  put (SHashMap _ hmap) = put (toList hmap)
  get = do
    hm <- get :: Get [(k, v)]
    return $ SHashMap [] (fromList hm)

