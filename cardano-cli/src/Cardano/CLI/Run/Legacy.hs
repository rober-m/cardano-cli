{-# LANGUAGE LambdaCase #-}

module Cardano.CLI.Run.Legacy
  ( LegacyClientCmdError
  , renderLegacyClientCmdError
  , runLegacyClientCommand
  ) where

import           Cardano.Api

import           Cardano.CLI.Commands.Governance
import           Cardano.CLI.EraBased.Legacy
import           Cardano.CLI.EraBased.Run.Governance
import           Cardano.CLI.Run.Legacy.Address
import           Cardano.CLI.Run.Legacy.Genesis
import           Cardano.CLI.Run.Legacy.Key
import           Cardano.CLI.Run.Legacy.Node
import           Cardano.CLI.Run.Legacy.Pool
import           Cardano.CLI.Run.Legacy.Query
import           Cardano.CLI.Run.Legacy.StakeAddress
import           Cardano.CLI.Run.Legacy.TextView
import           Cardano.CLI.Run.Legacy.Transaction

import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Trans.Except.Extra (firstExceptT)
import           Data.Text (Text)
import qualified Data.Text as Text

data LegacyClientCmdError
  = LegacyCmdAddressError !ShelleyAddressCmdError
  | LegacyCmdGenesisError !ShelleyGenesisCmdError
  | LegacyCmdGovernanceError !GovernanceCmdError
  | LegacyCmdNodeError !ShelleyNodeCmdError
  | LegacyCmdPoolError !ShelleyPoolCmdError
  | LegacyCmdStakeAddressError !ShelleyStakeAddressCmdError
  | LegacyCmdTextViewError !ShelleyTextViewFileError
  | LegacyCmdTransactionError !ShelleyTxCmdError
  | LegacyCmdQueryError !ShelleyQueryCmdError
  | LegacyCmdKeyError !ShelleyKeyCmdError

renderLegacyClientCmdError :: LegacyCommand -> LegacyClientCmdError -> Text
renderLegacyClientCmdError cmd err =
  case err of
    LegacyCmdAddressError addrCmdErr ->
       renderError cmd renderShelleyAddressCmdError addrCmdErr
    LegacyCmdGenesisError genesisCmdErr ->
       renderError cmd (Text.pack . displayError) genesisCmdErr
    LegacyCmdGovernanceError govCmdErr ->
       renderError cmd (Text.pack . displayError) govCmdErr
    LegacyCmdNodeError nodeCmdErr ->
       renderError cmd renderShelleyNodeCmdError nodeCmdErr
    LegacyCmdPoolError poolCmdErr ->
       renderError cmd renderShelleyPoolCmdError poolCmdErr
    LegacyCmdStakeAddressError stakeAddrCmdErr ->
       renderError cmd renderShelleyStakeAddressCmdError stakeAddrCmdErr
    LegacyCmdTextViewError txtViewErr ->
       renderError cmd renderShelleyTextViewFileError txtViewErr
    LegacyCmdTransactionError txErr ->
       renderError cmd renderShelleyTxCmdError txErr
    LegacyCmdQueryError queryErr ->
       renderError cmd renderShelleyQueryCmdError queryErr
    LegacyCmdKeyError keyErr ->
       renderError cmd renderShelleyKeyCmdError keyErr
  where
    renderError :: LegacyCommand -> (a -> Text) -> a -> Text
    renderError shelleyCmd renderer shelCliCmdErr =
      mconcat
        [ "Command failed: "
        , renderLegacyCommand shelleyCmd
        , "  Error: "
        , renderer shelCliCmdErr
        ]


--
-- CLI shelley command dispatch
--

runLegacyClientCommand :: LegacyCommand -> ExceptT LegacyClientCmdError IO ()
runLegacyClientCommand = \case
  LegacyAddressCmds      cmd -> firstExceptT LegacyCmdAddressError $ runAddressCmds cmd
  LegacyStakeAddressCmds cmd -> firstExceptT LegacyCmdStakeAddressError $ runStakeAddressCmds cmd
  LegacyKeyCmds          cmd -> firstExceptT LegacyCmdKeyError $ runKeyCmds cmd
  LegacyTransactionCmds  cmd -> firstExceptT LegacyCmdTransactionError $ runTransactionCmds cmd
  LegacyNodeCmds         cmd -> firstExceptT LegacyCmdNodeError $ runNodeCmds cmd
  LegacyPoolCmds         cmd -> firstExceptT LegacyCmdPoolError $ runPoolCmds cmd
  LegacyQueryCmds        cmd -> firstExceptT LegacyCmdQueryError $ runQueryCmds cmd
  LegacyGovernanceCmds   cmd -> firstExceptT LegacyCmdGovernanceError $ runGovernanceCmds cmd
  LegacyGenesisCmds      cmd -> firstExceptT LegacyCmdGenesisError $ runGenesisCmds cmd
  LegacyTextViewCmds     cmd -> firstExceptT LegacyCmdTextViewError $ runTextViewCmds cmd
