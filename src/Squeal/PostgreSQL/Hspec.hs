{-|
Helpers for creating database tests with hspec and squeal, inspired by Jonathan Fischoff's
[hspec-pg-transact](http://hackage.haskell.org/package/hspec-pg-transact).

This uses @tmp-postgres@ to automatically and connect to a temporary instance of postgres on a random port.

Tests can be written with 'itDB' which is wrapper around 'it' that uses the passed in 'TestDB' to run a db transaction automatically for the test.

The libary also provides a few other functions for more fine grained control over running transactions in tests.
-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures   #-}
{-# LANGUAGE MonoLocalBinds   #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TypeInType       #-}
{-# LANGUAGE TypeOperators    #-}
module Squeal.PostgreSQL.Hspec
where

import           Control.Exception
import           Control.Monad
import           Control.Monad.Base          (liftBase)
import           Control.Monad.Trans.Control (MonadBaseControl)
import qualified Data.ByteString.Char8       as BSC
import qualified Database.Postgres.Temp      as Temp
import           Generics.SOP                (K)
import           Squeal.PostgreSQL
import           Squeal.PostgreSQL.Migration
import           Squeal.PostgreSQL.Pool
import           Test.Hspec

data TestDB a = TestDB
  { tempDB :: Temp.DB
  -- ^ Handle for temporary @postgres@ process
  , pool   :: Pool a
  -- ^ Pool of 50 connections to the temporary @postgres@
  }

type Migrations schema m a = (MonadBaseControl IO m) =>
  PQ (("schema_migrations" ::: Table MigrationsTable) ': '[])
     (("schema_migrations" ::: Table MigrationsTable) ': schema) m a

type Fixtures schema = (Pool (K Connection schema) -> IO ())
type Actions schema a = PoolPQ schema IO a
type SquealContext (schema :: SchemaType) = TestDB (K Connection schema)

-- | Start a temporary @postgres@ process and create a pool of connections to it
setupDB
  :: Migrations schema IO a
  -> Fixtures schema
  -> IO (SquealContext schema)
setupDB migration fixtures = do
  tempDB <- either throwIO return =<< Temp.startAndLogToTmp []
  let connectionString = BSC.pack (Temp.connectionString tempDB)
  putStrLn $ Temp.connectionString tempDB
  let singleStripe = 1
      keepConnectionForOneHour = 3600
      poolSizeOfFifty = 50
  pool <- createConnectionPool
     connectionString
     singleStripe
     keepConnectionForOneHour
     poolSizeOfFifty
  withConnection connectionString migration
  fixtures pool
  pure TestDB {..}

-- | Drop all the connections and shutdown the @postgres@ process
teardownDB :: TestDB a -> IO ()
teardownDB TestDB {..} = do
  destroyAllResources pool
  void $ Temp.stop tempDB

-- | Run an 'IO' action with a connection from the pool
withPool :: TestDB (K Connection schema) -> Actions schema a -> IO a
withPool testDB = liftBase . flip runPoolPQ (pool testDB)

-- | Run an 'DB' transaction, using 'transactionally_'
withDB :: Actions schema a -> TestDB (K Connection schema) -> IO a
withDB action testDB =
  runPoolPQ (transactionally_ action) (pool testDB)

-- | Flipped version of 'withDB'
runDB :: TestDB (K Connection schema) -> Actions schema a -> IO a
runDB = flip withDB

-- | Helper for writing tests. Wrapper around 'it' that uses the passed
--   in 'TestDB' to run a db transaction automatically for the test.
itDB :: String -> Actions schema a -> SpecWith (TestDB (K Connection schema))
itDB msg action = it msg $ void . withDB action

-- | Wraps 'describe' with a
--
-- @
--   'beforeAll' ('setupDB' migrate)
-- @
--
-- hook for creating a db and a
--
-- @
--   'afterAll' 'teardownDB'
-- @
--
-- hook for stopping a db.
describeDB
  :: Migrations schema IO a
  -> Fixtures schema
  -> String
  -> SpecWith (SquealContext schema)
  -> Spec
describeDB migrate fixture str =
  beforeAll (setupDB migrate fixture) . afterAll teardownDB . describe str
