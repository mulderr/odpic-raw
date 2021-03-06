module Database.Dpi.Sql(
    getLanguage
  , setupLanguage
  , execute
  , queryAsRes
  , queryByPage
  , Name
  , SqlParam
  ) where

import           Database.Dpi
import           Database.Dpi.Field

import           Control.Monad          (void, when)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Acquire           (Acquire, mkAcquire, with)
import           Data.ByteString        (ByteString)
import           Data.ByteString.Char8  (unpack)
import           Data.Conduit
import qualified Data.Conduit.List      as CL
import           Data.Maybe
import           Data.Monoid            ((<>))
import           System.Environment

getLanguage :: OracleConfig -> IO ByteString
getLanguage conf = withContext $
  \cxt    -> withConnection cxt conf return $
    \conn -> do
      ((v:_):_)  <- queryByPage conn "SELECT USERENV ('language') FROM DUAL" [] (0,1)
      Just s :: Maybe ByteString <- fromDataField v
      return s

setupLanguage :: OracleConfig -> IO ()
setupLanguage conf = do
  nl <- lookupEnv "NLS_LANG"
  when (isNothing nl) $ getLanguage conf >>= setEnv "NLS_LANG" . unpack

type Name = ByteString
type SqlParam = (Name, IO DataValue)

-- | Execute SQL
execute :: PtrConn -> SQL -> [SqlParam] -> IO Int
execute conn sql ps = do
  st <- prepareStatement conn False sql
  bindValue st ps
  _  <- executeStatement st ModeExecDefault
  fromIntegral <$> getRowCount st

{-# INLINE bindValue #-}
bindValue :: PtrStmt -> [SqlParam] -> IO ()
bindValue = mapM_ . bd
  where
    bd st (name,value) = value >>= bindValueByName st name

-- | Query SQL
queryAsRes :: FromDataFields a => PtrConn -> SQL -> [SqlParam] -> Acquire (ConduitT () a IO ())
queryAsRes conn sql ps = do
  let {-# INLINE pst #-}
      pst = do
        st <- prepareStatement conn False sql
        bindValue st ps
        r  <- executeStatement st ModeExecDefault
        return (st,r)
      {-# INLINE meg #-}
      meg info value = DataField{..}
  (st,r) <- mkAcquire pst (void . releaseStatement . fst)
  let {-# INLINE pull #-}
      pull = do
        mayC <- liftIO $ fetch st
        case mayC of
          Nothing  -> return ()
          (Just _) -> do
            vs <- liftIO $ mapM (getQueryValue st) [1..r]
            qs <- liftIO $ mapM (getQueryInfo  st) [1..r]
            a  <- liftIO $ fromDataFields' $ zipWith meg qs vs
            yield a
            pull
  return pull

queryByPage :: FromDataFields a => PtrConn -> SQL -> [SqlParam] -> Page -> IO [a]
queryByPage conn sql ps (offset,limit) = do
  let sql' = sql <> " OFFSET " <> show offset <> " ROWS FETCH NEXT " <> show limit <> " ROWS ONLY"
  with (queryAsRes conn sql' ps) (\a -> runConduit $ a .| CL.fold (flip (:)) [])
