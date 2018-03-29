module Queries.Transfer where

import Composite.Record
import Control.Arrow (returnA)
import Control.Lens (view, _Unwrapping, (^.), _1, _2)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader (MonadReader, ask)
import Data.Int (Int64)
import Database.PostgreSQL.Simple (Connection)
import Data.Vinyl.Lens (rsubset)
import Opaleye (Query, Column, PGInt8, (.==), (.<=), (.>=), (.&&), runQuery, queryTable, restrict, constant, orderBy, desc)
import qualified Types.Transfer as Transfer
import qualified Types.Transaction as Transaction

-- | Get all transfers by transaction hash -- possibly more than one exists
getTransfersByHash
  :: ( MonadReader Connection m
     , MonadIO m
     )
  =>  Transaction.FTxHash
  -> m [Transfer.ApiTransferJson]
getTransfersByHash (Val txHash) = do
  conn <- ask
  (transfers :: [Record Transfer.DBTransfer]) <- liftIO . runQuery conn $ proc () -> do
    transfer <- queryTable Transfer.transferTable -< ()
    restrict -< transfer ^. Transaction.cTxHash .== constant txHash
    returnA -< transfer
  pure $ map (view (rsubset . _Unwrapping Transfer.ApiTransferJson)) transfers

-- | Get all transfers from a `sender`.
getTransfersBySender
  :: ( MonadReader Connection m
     , MonadIO m
     )
  =>  Transfer.FFrom
  -> m [Transfer.ApiTransferJson]
getTransfersBySender (Val sender) = do
  conn <- ask
  (transfers :: [Record Transfer.DBTransfer]) <- liftIO . runQuery conn $ proc () -> do
    transfer <- queryTable Transfer.transferTable -< ()
    restrict -< transfer ^. Transfer.cFrom .== constant sender
    returnA -< transfer
  pure $ map (view (rsubset . _Unwrapping Transfer.ApiTransferJson)) transfers

-- | Get all transfers in a block range
getTransfersInRange
  :: ( MonadReader Connection m
     , MonadIO m
     )
  => Transaction.FBlockNumber
  -> Transaction.FBlockNumber
  -> m [Transfer.ApiTransferByBlockJson]
getTransfersInRange (Val start) (Val end) = do
    conn <- ask
    (transfers :: [(Int64, Record Transfer.DBTransfer)]) <- liftIO . runQuery conn $ query
    let makeTransferWithBlock (bn, transfer) = (bn :*: transfer) ^. _Unwrapping Transfer.ApiTransferByBlockJson
    pure $ map makeTransferWithBlock transfers
  where
    query :: Query (Column PGInt8, Record Transfer.DBTransferCols)
    query = orderBy (desc fst) $ proc () -> do
      transfer <- queryTable Transfer.transferTable -< ()
      tx <- queryTable Transaction.transactionTable -< ()
      restrict -< transfer ^. Transaction.cTxHash .== tx ^. Transaction.cTxHash
      restrict -< tx ^. Transaction.cBlockNumber .>= constant start .&& tx ^. Transaction.cBlockNumber .<= constant end
      returnA -< (tx ^. Transaction.cBlockNumber , transfer)

{-
  $logInfo "received retrieve request"
  -- Increment the user retrieve requests ekg counter
  liftIO . Counter.inc =<< asks (view fUserRetrieveRequests . appMetrics)

  users <- withDb $ \ conn ->
    runQuery conn . limit 1 $ proc () -> do
      user <- queryTable userTable -< ()
      restrict -< view cId user .== constant userKey
      returnA -< user

  let _ = users :: [Record DbUser]
  case headMay users of
    Just user -> pure $ view (rsubset . _Unwrapping ApiUserJson) user
    Nothing -> throwError err404
-}
