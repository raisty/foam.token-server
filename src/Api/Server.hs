module Api.Server where

import Api.Api
import Data.Swagger (Swagger)
import Servant.Swagger (toSwagger)
import Composite.Record
import Control.Monad.Except (throwError)
import Control.Monad.Reader (ask)
import Data.Maybe (fromMaybe)
import Data.String.Conversions (cs)
import Servant
import Servant.Server
import Types.Orphans ()
import Network.Ethereum.Web3.Types
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import qualified Network.Ethereum.Web3.Eth as Eth
import Queries.Transfer
import qualified Types.Transfer as Transfer
import qualified Types.Transaction as Transaction
import Types.Application

-- | get all the transfers for a transaction based on the hash
-- | -- a singler transaction can cause more than one transfer.
getTransfersByTransactionHash
  :: Transaction.FTxHash
  -> AppHandler [Transfer.ApiTransferJson]
getTransfersByTransactionHash = getTransfersByHash

-- | Get all transfers from a certain sender, with the option to specify the range
-- | to within a certain block interval including the endpoints
getTransfersBySender
  :: Transfer.FFrom
  -> Maybe Transaction.FBlockNumber
  -> Maybe Transaction.FBlockNumber
  -> AppHandler [Transfer.ApiTransferByBlockJson]
getTransfersBySender sender mStart mEnd = do
    let start = fromMaybe (Val 0) mStart
    end <- maybe (Val . fromInteger <$> getBlockNumber) pure mEnd
    getTransfersInRange (Just sender) start end
  where
    getBlockNumber :: AppHandler Integer
    getBlockNumber = do
      ebn <- web3Request Eth.blockNumber
      case ebn of
        Left err -> throwError $ err500 {errBody = cs $ show err}
        Right (BlockNumber res) -> pure res

-- | Token server
tokenServer :: ServerT TokenApi AppHandler
tokenServer =
       getTransfersByTransactionHash
  :<|> getTransfersBySender

-- | Swagger
getSwagger :: Swagger
getSwagger = toSwagger tokenApi


-- | Api server
startServer :: IO ()
startServer = do
  cfg <- makeAppConfig
  let server = pure getSwagger :<|> enter (transformAppHandler cfg) tokenServer
  run 9000 $
    logStdoutDev $
    serve api server
