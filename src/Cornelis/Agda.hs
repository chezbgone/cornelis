{-# LANGUAGE NumDecimals       #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}

module Cornelis.Agda where

import           Control.Concurrent.Chan.Unagi (writeChan)
import           Control.Lens
import           Control.Monad.IO.Class
import           Control.Monad.State
import           Cornelis.Debug (reportExceptions)
import           Cornelis.InfoWin (buildInfoBuffer)
import           Cornelis.Types
import           Cornelis.Types.Agda
import           Cornelis.Utils
import           Data.Aeson
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import           Data.Text.Lazy.Encoding (encodeUtf8)
import           Data.Text.Lazy.IO (hGetLine)
import           Neovim hiding (err)
import           Neovim.API.Text
import           System.IO hiding (hGetLine)
import           System.Process


------------------------------------------------------------------------------
-- | When true, dump out received JSON as it arrives.
debugJson :: Bool
debugJson = False


------------------------------------------------------------------------------
-- | Create an 'Agda' environment for the given buffer. This spawns an
-- asynchronous thread that keeps an agda process alive as long as vim is open.
--
-- TODO(sandy): This leaks the process when the buffer is closed.
spawnAgda :: Buffer -> Neovim CornelisEnv Agda
spawnAgda buffer = do
  (m_in, m_out, _, hdl) <-
    liftIO $ createProcess $
      (proc "agda" ["--interaction-json"])
        { std_in = CreatePipe , std_out = CreatePipe }
  case (m_in, m_out) of
    (Just hin, Just hout) -> do
      liftIO $ do
        hSetBuffering hin NoBuffering
        hSetBuffering hout NoBuffering

      void $ neovimAsync $ forever $ reportExceptions $ do
        resp <- liftIO $ hGetLine hout
        chan <- asks ce_stream
        case eitherDecode @Response $ encodeUtf8 $ (dropPrefix "JSON> ") resp of
          Left err -> vim_report_error $ T.pack err
          Right res -> do
            case res of
              HighlightingInfo _ _ -> pure ()
              _ -> when debugJson $ vim_report_error $ T.pack $ show resp
            liftIO $ writeChan chan $ AgdaResp buffer res

      pure $ Agda buffer hin hdl
    (_, _) -> error "can't start agda"


------------------------------------------------------------------------------
-- | Drop a prefix from the text, if it exists.
dropPrefix :: LT.Text -> LT.Text -> LT.Text
dropPrefix pref msg
  | LT.isPrefixOf pref msg = LT.drop (LT.length pref) msg
  | otherwise = msg


------------------------------------------------------------------------------
-- | Send an 'Interaction' to an 'Agda'.
runIOTCM :: Interaction -> Agda -> Neovim env ()
runIOTCM i agda = do
  iotcm <- buildIOTCM i $ a_buffer agda
  liftIO $ hPrint (a_req agda) iotcm


------------------------------------------------------------------------------
-- | Construct an 'IOTCM' for a buffer.
buildIOTCM :: Interaction -> Buffer -> Neovim env IOTCM
buildIOTCM i buffer = do
  fp <- buffer_get_name buffer
  pure $ IOTCM fp NonInteractive Direct i


------------------------------------------------------------------------------
-- | Get the current buffer and run the continuation.
withCurrentBuffer :: (Buffer -> Neovim env a) -> Neovim env a
withCurrentBuffer f = vim_get_current_buffer >>= f


------------------------------------------------------------------------------
-- | Ensure we have a 'BufferStuff' attached to the current buffer.
withAgda :: Neovim CornelisEnv a -> Neovim CornelisEnv a
withAgda m = do
  buffer <- vim_get_current_buffer
  gets (M.lookup buffer . cs_buffers) >>= \case
    Just _ -> m
    Nothing -> do
      agda <- spawnAgda buffer
      iw <- buildInfoBuffer
      modify' $ #cs_buffers %~ M.insert buffer BufferStuff
        { bs_agda_proc = agda
        , bs_ips = mempty
        , bs_goto_sites = mempty
        , bs_goals = AllGoalsWarnings [] [] [] []
        , bs_info_win = iw
        }
      m


------------------------------------------------------------------------------
-- | Get the 'Agda' environment for a given buffer.
getAgda :: Buffer -> Neovim CornelisEnv Agda
getAgda buffer = gets $ bs_agda_proc . (M.! buffer) . cs_buffers

