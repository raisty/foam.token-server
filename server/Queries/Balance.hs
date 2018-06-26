{-# LANGUAGE TypeApplications #-}

module Queries.Balance
  ( getBalances
  , getRichestHolders
  ) where

import Data.Ord (Down(..))
import Control.Monad (join)
import qualified Control.Exception as Exception
import Control.Concurrent.Async
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, runReaderT, ask)
import Network.Ethereum.ABI.Prim.Address
import Network.Ethereum.Web3.Types
import Network.Ethereum.Web3.Provider
import Network.Ethereum.ABI.Prim.Int
import qualified Contracts.ERC20 as ERC20
import Data.Hashable (Hashable(..))
import Data.Traversable (forM)
import Data.Typeable
import Haxl.Core
import Types.Application (AppConfig(..), Web3Config(..))
import Queries.Transfer
import Data.Default (def)
import Data.Int (Int64)
import qualified Data.List as L


getBalances
  :: ( MonadReader AppConfig m
     , MonadIO m
     )
  => Quantity
  -> [Address]
  -> m [(Address, Integer)]
getBalances bn addrs = do
  cfg <- ask
  let st = EthState {appConfig = cfg}
  liftIO $ do
    e <- initEnv (stateSet st stateEmpty) ()
    balances <- runHaxl e $ mapM (getBalanceOf bn) addrs
    return $ zipWith (\a b -> (a, toInteger b)) addrs balances

getRichestNeighbors
  :: ( MonadReader AppConfig m
     , MonadIO m
     )
  => Quantity
  -> Address
  -> m [(Address, Integer)]
getRichestNeighbors bn userAddress = do
    (start, end) <- getBlockRange
    cfg <- ask
    let st = EthState {appConfig = cfg}
    liftIO $ do
      e <- initEnv (stateSet st stateEmpty) ()
      runHaxl e $ do
        traders <- getTradersInBlockRange (toBN start) (toBN end) userAddress
        pairs <- forM traders $ \trader -> do
          bal <- toInteger <$> getBalanceOf bn trader
          pure (trader, bal)
        let pairs' = filter ((> 0) . snd) pairs
        pure . take 10 . L.sortOn (Down . snd) $ pairs'
  where
    toBN = fromInteger @Quantity . toInteger

-- | Request Algebra
data EthReq a where
  BalanceOf :: Quantity -> Address -> EthReq (UIntN 256)
  GetTraders :: Quantity -> Quantity -> Address -> EthReq [Address]
  deriving (Typeable)

-- | Boilerplate
deriving instance Eq (EthReq a)
deriving instance Show (EthReq a)

instance Hashable (EthReq a) where
   hashWithSalt s (BalanceOf bn a) = hashWithSalt s (0::Int, show bn, toHexString a)
   hashWithSalt s (GetTraders start end from) = hashWithSalt s (1::Int, show start, show end, toHexString from)

-- | The only global state is the ERC20 address
instance StateKey EthReq where
  data State EthReq = EthState {appConfig :: AppConfig}

instance ShowP EthReq where showp = show

instance DataSourceName EthReq where
  dataSourceName _ = "EthDataSource"

instance DataSource u EthReq where
  fetch _state _flags _user bfs = AsyncFetch $ \inner -> do
    asyncs <- mapM (fetchAsync _state) bfs
    inner
    mapM_ wait asyncs

-- Queries
getBalanceOf :: Quantity -> Address -> GenHaxl u (UIntN 256)
getBalanceOf bn addr = dataFetch (BalanceOf bn addr)

getTradersInBlockRange :: Quantity -> Quantity -> Address -> GenHaxl u [Address]
getTradersInBlockRange start end from = dataFetch (GetTraders start end from)

-- Helpers

fetchAsync
  :: State EthReq
  -> BlockedFetch EthReq
  -> IO (Async ())
fetchAsync _state (BlockedFetch req rvar) =
  async $ do
    e <- Exception.try $ fetchEthReq _state req
    case e of
      Left ex -> putFailure rvar (ex :: Exception.SomeException)
      Right a -> putSuccess rvar a

fetchEthReq
  :: State EthReq
  -> EthReq a
  -> IO a
fetchEthReq EthState{..} (BalanceOf bn user) = do
  let txOpts = def { callTo = Just $ erc20Address appConfig
                   }
  eRes <- runWeb3With (manager . web3 $ appConfig) (provider . web3 $ appConfig) $ ERC20.balanceOf txOpts user Latest
  case eRes of
    Left err -> Exception.throw (error (show err) :: Exception.SomeException)
    Right res -> pure res
fetchEthReq EthState{..} (GetTraders start end from) =
  runReaderT (getTransfersFromInRange from start end) appConfig
