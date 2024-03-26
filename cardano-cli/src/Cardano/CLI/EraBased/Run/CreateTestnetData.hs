{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

{- HLINT ignore "Redundant <$>" -}
{- HLINT ignore "Use let" -}

module Cardano.CLI.EraBased.Run.CreateTestnetData
  ( genStuffedAddress
    , getCurrentTimePlus30
    , readRelays
    , readAndDecodeGenesisFile
    , runGenesisKeyGenUTxOCmd
    , runGenesisKeyGenGenesisCmd
    , runGenesisKeyGenDelegateCmd
    , runGenesisCreateTestNetDataCmd
    , runGenesisKeyGenDelegateVRF
  ) where

import           Cardano.Api hiding (ConwayEra)
import           Cardano.Api.Ledger (StrictMaybe (SNothing))
import qualified Cardano.Api.Ledger as L
import           Cardano.Api.Shelley (Address (ShelleyAddress),
                   Hash (DRepKeyHash, GenesisDelegateKeyHash, GenesisKeyHash, StakeKeyHash, VrfKeyHash),
                   KESPeriod (KESPeriod),
                   OperationalCertificateIssueCounter (OperationalCertificateIssueCounter),
                   ShelleyGenesis (ShelleyGenesis, sgGenDelegs, sgInitialFunds, sgMaxLovelaceSupply, sgNetworkMagic, sgProtocolParams, sgStaking, sgSystemStart),
                   StakeCredential (StakeCredentialByKey), VerificationKey (VrfVerificationKey),
                   VrfKey, alonzoGenesisDefaults, conwayGenesisDefaults, shelleyGenesisDefaults,
                   toShelleyAddr, toShelleyNetwork, toShelleyStakeAddr)

import           Cardano.CLI.EraBased.Commands.Genesis as Cmd
import qualified Cardano.CLI.EraBased.Commands.Governance.DRep as DRep
import qualified Cardano.CLI.EraBased.Commands.Node as Cmd
import           Cardano.CLI.EraBased.Run.Address (generateAndWriteKeyFiles)
import qualified Cardano.CLI.EraBased.Run.Governance.DRep as DRep
import qualified Cardano.CLI.EraBased.Run.Key as Key
import           Cardano.CLI.EraBased.Run.Node (runNodeIssueOpCertCmd, runNodeKeyGenColdCmd,
                   runNodeKeyGenKesCmd, runNodeKeyGenVrfCmd)
import           Cardano.CLI.EraBased.Run.StakeAddress (runStakeAddressKeyGenCmd)
import qualified Cardano.CLI.IO.Lazy as Lazy
import           Cardano.CLI.Types.Common
import           Cardano.CLI.Types.Errors.GenesisCmdError
import           Cardano.CLI.Types.Errors.NodeCmdError
import           Cardano.CLI.Types.Errors.StakePoolCmdError
import           Cardano.CLI.Types.Key
import           Cardano.Crypto.Hash (HashAlgorithm)
import qualified Cardano.Crypto.Hash as Hash
import qualified Cardano.Crypto.Random as Crypto
import           Ouroboros.Consensus.Shelley.Node (ShelleyGenesisStaking (..))

import           Control.DeepSeq (NFData, deepseq)
import           Control.Monad (forM, forM_, unless, void, when)
import qualified Data.Aeson as Aeson
import           Data.Bifunctor (Bifunctor (..))
import qualified Data.Binary.Get as Bin
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Coerce (coerce)
import           Data.Data (Proxy (..))
import           Data.ListMap (ListMap (..))
import qualified Data.ListMap as ListMap
import           Data.Map.Strict (Map, fromList, toList)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import qualified Data.Sequence.Strict as Seq
import           Data.String (fromString)
import qualified Data.Text as Text
import           Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import           Data.Tuple (swap)
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           GHC.Num (Natural)
import           Lens.Micro ((^.))
import           System.Directory (createDirectoryIfMissing)
import           System.FilePath ((</>))
import qualified System.Random as Random
import           System.Random (StdGen)

import           Crypto.Random (getRandomBytes)

runGenesisKeyGenGenesisCmd
  :: GenesisKeyGenGenesisCmdArgs
  -> ExceptT GenesisCmdError IO ()
runGenesisKeyGenGenesisCmd
    Cmd.GenesisKeyGenGenesisCmdArgs
    { Cmd.verificationKeyPath
    , Cmd.signingKeyPath
    } = do
    skey <- generateSigningKey AsGenesisKey
    let vkey = getVerificationKey skey
    firstExceptT GenesisCmdGenesisFileError . newExceptT $ do
      void $ writeLazyByteStringFile signingKeyPath $ textEnvelopeToJSON (Just skeyDesc) skey
      writeLazyByteStringFile verificationKeyPath $ textEnvelopeToJSON (Just Key.genesisVkeyDesc) vkey
  where
    skeyDesc :: TextEnvelopeDescr
    skeyDesc = "Genesis Signing Key"


runGenesisKeyGenDelegateCmd
  :: GenesisKeyGenDelegateCmdArgs
  -> ExceptT GenesisCmdError IO ()
runGenesisKeyGenDelegateCmd
    Cmd.GenesisKeyGenDelegateCmdArgs
    { Cmd.verificationKeyPath
    , Cmd.signingKeyPath
    , Cmd.opCertCounterPath
    } = do
    skey <- generateSigningKey AsGenesisDelegateKey
    let vkey = getVerificationKey skey
    firstExceptT GenesisCmdGenesisFileError . newExceptT $ do
      void $ writeLazyByteStringFile signingKeyPath
        $ textEnvelopeToJSON (Just skeyDesc) skey
      void $ writeLazyByteStringFile verificationKeyPath
        $ textEnvelopeToJSON (Just Key.genesisVkeyDelegateDesc) vkey
      writeLazyByteStringFile opCertCounterPath
        $ textEnvelopeToJSON (Just certCtrDesc)
        $ OperationalCertificateIssueCounter
            initialCounter
            (castVerificationKey vkey)  -- Cast to a 'StakePoolKey'
  where
    skeyDesc, certCtrDesc :: TextEnvelopeDescr
    skeyDesc = "Genesis delegate operator key"
    certCtrDesc = "Next certificate issue number: "
               <> fromString (show initialCounter)

    initialCounter :: Word64
    initialCounter = 0


runGenesisKeyGenDelegateVRF ::
     VerificationKeyFile Out
  -> SigningKeyFile Out
  -> ExceptT GenesisCmdError IO ()
runGenesisKeyGenDelegateVRF vkeyPath skeyPath = do
    skey <- generateSigningKey AsVrfKey
    let vkey = getVerificationKey skey
    firstExceptT GenesisCmdGenesisFileError . newExceptT $ do
      void $ writeLazyByteStringFile skeyPath
        $ textEnvelopeToJSON (Just skeyDesc) skey
      writeLazyByteStringFile vkeyPath
        $ textEnvelopeToJSON (Just vkeyDesc) vkey
  where
    skeyDesc, vkeyDesc :: TextEnvelopeDescr
    skeyDesc = "VRF Signing Key"
    vkeyDesc = "VRF Verification Key"

runGenesisKeyGenUTxOCmd
  :: GenesisKeyGenUTxOCmdArgs
  -> ExceptT GenesisCmdError IO ()
runGenesisKeyGenUTxOCmd
    Cmd.GenesisKeyGenUTxOCmdArgs
    { Cmd.verificationKeyPath
    , Cmd.signingKeyPath
    } = do
    skey <- generateSigningKey AsGenesisUTxOKey
    let vkey = getVerificationKey skey
    firstExceptT GenesisCmdGenesisFileError . newExceptT $ do
      void $ writeLazyByteStringFile signingKeyPath
        $ textEnvelopeToJSON (Just skeyDesc) skey
      writeLazyByteStringFile verificationKeyPath
        $ textEnvelopeToJSON (Just vkeyDesc) vkey
  where
    skeyDesc, vkeyDesc :: TextEnvelopeDescr
    skeyDesc = "Genesis Initial UTxO Signing Key"
    vkeyDesc = "Genesis Initial UTxO Verification Key"

runGenesisCreateTestNetDataCmd
  :: GenesisCreateTestNetDataCmdArgs
  -> ExceptT GenesisCmdError IO ()
runGenesisCreateTestNetDataCmd Cmd.GenesisCreateTestNetDataCmdArgs
  { networkId
  , specShelley
  , specAlonzo
  , specConway
  , numGenesisKeys
  , numPools
  , stakeDelegators = StakeDelegators { stakeDelegatorsGenerationMode
                                      , numOfStakeDelegators
                                      }
  , numDRepKeys = DRepCredentials { dRepCredentialGenerationMode
                                  , numOfDRepCredentials
                                  }
  , numStuffedUtxo
  , numUtxoKeys
  , totalSupply
  , delegatedSupply
   , relays
  , systemStart
  , outputDir
  } = do
  liftIO $ createDirectoryIfMissing False outputDir
  shelleyGenesisInit <- maybeReadAndDecodeGenesisFileSpec specShelley shelleyGenesisDefaults
  alonzoGenesis <- maybeReadAndDecodeGenesisFileSpec specAlonzo alonzoGenesisDefaults
  conwayGenesis <- maybeReadAndDecodeGenesisFileSpec specConway conwayGenesisDefaults

  -- Read NetworkId either from file or from the flag. Flag overrides template file.
  let actualNetworkId =
        case networkId of
          Just networkFromFlag -> networkFromFlag
          Nothing -> fromNetworkMagic (NetworkMagic $ sgNetworkMagic shelleyGenesisInit)
      shelleyGenesis = shelleyGenesisInit { sgNetworkMagic = unNetworkMagic (toNetworkMagic actualNetworkId) }
      -- {0 -> genesis-keys/genesis0/key.vkey, 1 -> genesis-keys/genesis1/key.vkey, ...}
      genesisVKeysPaths = mkPaths numGenesisKeys genesisDir "genesis" "key.vkey"
      -- {0 -> delegate-keys/delegate0/key.vkey, 1 -> delegate-keys/delegate1/key.vkey, ...}
      delegateKeys = mkPaths numGenesisKeys delegateDir "delegate" "key.vkey"
      -- {0 -> delegate-keys/delegate0/vrf.vkey, 1 -> delegate-keys/delegate1/vrf.vkey, ...}
      delegateVrfKeys = mkPaths numGenesisKeys delegateDir "delegate" "vrf.vkey"
      -- {"stake-delegators/delegator1", "stake-delegators/delegator2", ...}
      stakeDelegatorsDirs = [stakeDelegatorsDir </> "delegator" <> show i | i <- [1 .. numOfStakeDelegators]]

  forM_ [ 1 .. numGenesisKeys ] $ \index -> do
    createGenesisKeys (genesisDir </> ("genesis" <> show index))
    createDelegateKeys desiredKeyOutputFormat (delegateDir </> ("delegate" <> show index))

  when (0 < numGenesisKeys) $ do
    writeREADME genesisDir genesisREADME
    writeREADME delegateDir delegatesREADME

  -- UTxO keys
  let utxoKeyFileNames = [utxoKeysDir </> ("utxo" <> show index) </> "utxo.vkey"
                           | index <-  [ 1 .. numUtxoKeys ]]
  forM_ [ 1 .. numUtxoKeys ] $ \index ->
       createUtxoKeys (utxoKeysDir </> ("utxo" <> show index))

  when (0 < numUtxoKeys) $ writeREADME utxoKeysDir utxoKeysREADME

  mSPOsRelays <- forM relays readRelays
  case (relays, mSPOsRelays) of
    (Just fp, Just stakePoolRelays) | Map.size stakePoolRelays > fromIntegral numPools ->
      throwError $ GenesisCmdTooManyRelaysError fp (fromIntegral numPools) (Map.size stakePoolRelays)
    _ -> pure ()

  -- Pools
  poolParams <- forM [ 1 .. numPools ] $ \index -> do
    let poolDir = poolsDir </> ("pool" <> show index)

    createPoolCredentials desiredKeyOutputFormat poolDir
    -- Indexes of directories created on disk start at 1, but
    -- indexes in terms of the relays' list start at 0. Hence 'index - 1' here:
    buildPoolParams actualNetworkId poolDir (index - 1) (fromMaybe mempty mSPOsRelays)

  when (0 < numPools) $ writeREADME poolsDir poolsREADME

  -- DReps
  g <- Random.getStdGen

  dRepKeys <- firstExceptT GenesisCmdFileError $
    case dRepCredentialGenerationMode of
      OnDisk -> forM [ 1 .. numOfDRepCredentials ] $ \index -> do
                  let drepDir = drepsDir </> "drep" <> show index
                      vkeyFile = File @(VerificationKey ()) $ drepDir </> "drep.vkey"
                      skeyFile = File @(SigningKey ()) $ drepDir </> "drep.skey"
                      cmd = DRep.GovernanceDRepKeyGenCmdArgs ConwayEraOnwardsConway vkeyFile skeyFile
                  liftIO $ createDirectoryIfMissing True drepDir
                  fst <$> DRep.runGovernanceDRepKeyGenCmd cmd
      Transient -> liftIO $ mapAccumM (\g' _ -> swap . first getVerificationKey <$> generateInsecureSigningKey g' AsDRepKey)
                                      g [ 1 .. numOfStakeDelegators ]

  when (0 < numOfDRepCredentials && dRepCredentialGenerationMode == OnDisk) $ writeREADME drepsDir drepsREADME


  -- Stake delegators
  g2 <- Random.getStdGen
  delegatorKeys <- case stakeDelegatorsGenerationMode of
    OnDisk -> forM stakeDelegatorsDirs $ \delegator -> createStakeDelegatorCredentials delegator
    Transient -> liftIO $ mapAccumM (\g' _ -> computeInsecureStakeKeyAddr g') g2 [ 1 .. numOfStakeDelegators ]

  let (delegsPerPool, delegsRemaining) =
        if numPools == 0
        then (0, 0)
        else numOfStakeDelegators `divMod` numPools
      delegsForPool poolIx =
        if poolIx <= delegsRemaining
        then delegsPerPool + 1
        else delegsPerPool
      distribution = [pool | (pool, poolIx) <- zip poolParams [1 ..], _ <- [1 .. delegsForPool poolIx]]

  -- Distribute M delegates across N pools:
  let delegations = zipWithDeepSeq (computeDelegation actualNetworkId) delegatorKeys distribution

  genDlgs <- readGenDelegsMap genesisVKeysPaths delegateKeys delegateVrfKeys
  nonDelegAddrs <- readInitialFundAddresses utxoKeyFileNames actualNetworkId
  start <- maybe (SystemStart <$> getCurrentTimePlus30) pure systemStart

  let network = toShelleyNetwork actualNetworkId
  stuffedUtxoAddrs <- liftIO $ Lazy.replicateM (fromIntegral numStuffedUtxo) $ genStuffedAddress network


  let conwayGenesis' = addDRepsToConwayGenesis dRepKeys (map snd delegatorKeys) conwayGenesis

  let stake = second L.ppId . mkDelegationMapEntry <$> delegations
      stakePools = [ (L.ppId poolParams', poolParams') | poolParams' <- snd . mkDelegationMapEntry <$> delegations ]
      delegAddrs = dInitialUtxoAddr <$> delegations
  !shelleyGenesis' <-
    updateOutputTemplate
      start genDlgs totalSupply nonDelegAddrs stakePools stake delegatedSupply (length delegations)
      delegAddrs stuffedUtxoAddrs shelleyGenesis

  -- Write genesis.json file to output
  liftIO $ LBS.writeFile (outputDir </> "conway-genesis.json") $ Aeson.encode conwayGenesis'
  liftIO $ LBS.writeFile (outputDir </> "shelley-genesis.json") $ Aeson.encode shelleyGenesis'
  liftIO $ LBS.writeFile (outputDir </> "alonzo-genesis.json") $ Aeson.encode alonzoGenesis
  where
    genesisDir = outputDir </> "genesis-keys"
    delegateDir = outputDir </> "delegate-keys"
    drepsDir = outputDir </> "drep-keys"
    utxoKeysDir = outputDir </> "utxo-keys"
    poolsDir = outputDir </> "pools-keys"
    stakeDelegatorsDir = outputDir </> "stake-delegators"
    mkDelegationMapEntry :: Delegation -> (L.KeyHash L.Staking L.StandardCrypto, L.PoolParams L.StandardCrypto)
    mkDelegationMapEntry d = (dDelegStaking d, dPoolParams d)

    addDRepsToConwayGenesis :: [VerificationKey DRepKey] -> [VerificationKey StakeKey]
                            -> L.ConwayGenesis L.StandardCrypto -> L.ConwayGenesis L.StandardCrypto
    addDRepsToConwayGenesis dRepKeys stakingKeys conwayGenesis =
      conwayGenesis { L.cgDelegs = delegs (zip stakingKeys (case dRepKeys of [] -> []; _ -> cycle dRepKeys))
                    , L.cgInitialDReps = initialDReps (L.ucppDRepDeposit $ L.cgUpgradePParams conwayGenesis) dRepKeys
                    }

      where
      delegs :: [(VerificationKey StakeKey, VerificationKey DRepKey)] -> ListMap (L.Credential L.Staking L.StandardCrypto) (L.Delegatee L.StandardCrypto)
      delegs = ListMap.fromList . map (bimap verificationKeytoStakeCredential (L.DelegVote . L.DRepCredential . verificationKeyToDRepCredential))

      initialDReps :: L.Coin -> [VerificationKey DRepKey] -> ListMap (L.Credential L.DRepRole L.StandardCrypto) (L.DRepState L.StandardCrypto)
      initialDReps minDeposit = ListMap.fromList . map (\c -> ( verificationKeyToDRepCredential c
                                                              , L.DRepState { L.drepExpiry = EpochNo 1_000
                                                                            , L.drepAnchor = SNothing
                                                                            , L.drepDeposit = max (L.Coin 1_000_000) minDeposit
                                                                            }))

      verificationKeyToDRepCredential :: VerificationKey DRepKey -> L.Credential L.DRepRole L.StandardCrypto
      verificationKeyToDRepCredential vk = dRepKeyToCredential (verificationKeyHash vk)
        where
          dRepKeyToCredential :: Hash DRepKey -> L.Credential L.DRepRole L.StandardCrypto
          dRepKeyToCredential (DRepKeyHash v) = L.KeyHashObj v

      verificationKeytoStakeCredential :: VerificationKey StakeKey -> L.Credential L.Staking L.StandardCrypto
      verificationKeytoStakeCredential vk = stakeKeyToCredential (verificationKeyHash vk)
        where
          stakeKeyToCredential :: Hash StakeKey -> L.Credential L.Staking L.StandardCrypto
          stakeKeyToCredential (StakeKeyHash v) = L.KeyHashObj v

    -- | 'zipWithDeepSeq' is like 'zipWith' but it ensures each element of the result is fully
    -- evaluated before calculating the rest of the list. We do this in order to avoid the
    -- case were we expand the intermediate representation (the two input lists) before
    -- converging to the result. The intermediate representation is larger than the result,
    -- so we try to avoid having it all in memory at once to reduce the memory footprint.
    zipWithDeepSeq :: NFData c => (a -> b -> c) -> [a] -> [b] -> [c]
    zipWithDeepSeq _ _ [] = []
    zipWithDeepSeq _ [] _ = []
    zipWithDeepSeq f (h1:t1) (h2:t2) = let h = f h1 h2 in
                                       h `deepseq` (h:zipWithDeepSeq f t1 t2)

    -- | Manually implemented (because the one in Data.Traversable requires `base-4.18` or greater)
    mapAccumM :: (acc -> b -> IO (acc, c)) -> acc -> [b] -> IO [c]
    mapAccumM _ _ [] = return []
    mapAccumM f a (h:t) = do (a', h') <- f a h
                             rest <- mapAccumM f a' t
                             return $ h':rest

-- | The output format used all along this file
desiredKeyOutputFormat :: KeyOutputFormat
desiredKeyOutputFormat = KeyOutputFormatTextEnvelope

writeREADME :: ()
  => FilePath
  -> Text.Text
  -> ExceptT GenesisCmdError IO ()
writeREADME dir content = do
  firstExceptT GenesisCmdFileError . newExceptT $ writeTextFile file content
  where
    file :: File Text.Text Out = File $ dir </> "README.md"

genesisREADME :: Text.Text
genesisREADME = Text.intercalate "\n"
  ["Keys generated by the --genesis-keys flag. In Byron these keys were used to mint blocks and initiate hard forks."
   , "Starting with Shelley and decentralization, blocks started being produced by other keys than genesis keys."
   , "Still, these keys were required to trigger hard forks."
   , "With the introduction of Conway, these keys should become useless"]

delegatesREADME :: Text.Text
delegatesREADME = Text.intercalate "\n"
  ["Keys generated by the --genesis-keys flag. These keys are used to mint blocks when not being completely decentralized",
   "(e.g. when stake pools are not the sole block producers). These keys are intended to run nodes."]

drepsREADME :: Text.Text
drepsREADME = Text.intercalate "\n"
  ["Keys generated by the --drep-keys flag. These keys are for Delegate Representatives (DReps) that make decisions in",
   "Funds of the Catalyst Project. Delegators that do not want to vote for each decision will pick DReps in line with",
   "their views delegate their voting power to them. The DRep's in this generated testnet data will automatically get",
   "registered and all the stake delegators (if any) will automatically delegate their vote to one of the DReps here."]

utxoKeysREADME :: Text.Text
utxoKeysREADME = Text.intercalate "\n"
  ["Keys generated by the --utxo-keys flag. These keys receive a portion of the supply."]

poolsREADME :: Text.Text
poolsREADME = Text.intercalate "\n"
  ["Keys generated by the --pools flag. These keys are intended to run nodes."]

-- | @mkPaths numKeys dir segment filename@ returns the paths to the keys to generate.
-- For example @mkPaths 3 dir prefix fn.ext@ returns
-- [dir/segment1/fn.ext, dir/segment2/fn.ext, dir/segment3/fn.ext]
mkPaths :: Word -> String -> String -> String -> Map Int FilePath
mkPaths numKeys dir segment filename =
  fromList [(fromIntegral idx, dir </> (segment <> show idx) </> filename)
            | idx <- [1 .. numKeys]]

genStuffedAddress :: L.Network -> IO (AddressInEra ShelleyEra)
genStuffedAddress network =
  shelleyAddressInEra ShelleyBasedEraShelley <$>
  (ShelleyAddress
   <$> pure network
   <*> (L.KeyHashObj . mkKeyHash . read64BitInt
         <$> Crypto.runSecureRandom (getRandomBytes 8))
   <*> pure L.StakeRefNull)
   where
    read64BitInt :: ByteString -> Int
    read64BitInt = (fromIntegral :: Word64 -> Int)
      . Bin.runGet Bin.getWord64le . LBS.fromStrict

    mkDummyHash :: forall h a. HashAlgorithm h => Proxy h -> Int -> Hash.Hash h a
    mkDummyHash _ = coerce . L.hashWithSerialiser @h L.toCBOR

    mkKeyHash :: forall c discriminator. L.Crypto c => Int -> L.KeyHash discriminator c
    mkKeyHash = L.KeyHash . mkDummyHash (Proxy @(L.ADDRHASH c))

createDelegateKeys :: KeyOutputFormat -> FilePath -> ExceptT GenesisCmdError IO ()
createDelegateKeys fmt dir = do
  liftIO $ createDirectoryIfMissing True dir
  runGenesisKeyGenDelegateCmd
    Cmd.GenesisKeyGenDelegateCmdArgs
    { Cmd.verificationKeyPath = File @(VerificationKey ()) $ dir </> "key.vkey"
    , Cmd.signingKeyPath = onlyOut coldSK
    , Cmd.opCertCounterPath = onlyOut opCertCtr
    }
  runGenesisKeyGenDelegateVRF
        (File @(VerificationKey ()) $ dir </> "vrf.vkey")
        (File @(SigningKey ()) $ dir </> "vrf.skey")
  firstExceptT GenesisCmdNodeCmdError $ do
    runNodeKeyGenKesCmd $ Cmd.NodeKeyGenKESCmdArgs
        fmt
        (onlyOut kesVK)
        (File @(SigningKey ()) $ dir </> "kes.skey")
    runNodeIssueOpCertCmd $ Cmd.NodeIssueOpCertCmdArgs
        (VerificationKeyFilePath (onlyIn kesVK))
        (onlyIn coldSK)
        opCertCtr
        (KESPeriod 0)
        (File $ dir </> "opcert.cert")
 where
   kesVK = File @(VerificationKey ()) $ dir </> "kes.vkey"
   coldSK = File @(SigningKey ()) $ dir </> "key.skey"
   opCertCtr = File $ dir </> "opcert.counter"

createGenesisKeys :: FilePath -> ExceptT GenesisCmdError IO ()
createGenesisKeys dir = do
  liftIO $ createDirectoryIfMissing True dir
  runGenesisKeyGenGenesisCmd
    GenesisKeyGenGenesisCmdArgs
    { verificationKeyPath = File @(VerificationKey ()) $ dir </> "key.vkey"
    , signingKeyPath = File @(SigningKey ()) $ dir </> "key.skey"
    }

createStakeDelegatorCredentials :: FilePath
                                -> ExceptT GenesisCmdError IO (VerificationKey PaymentKey,
                                                               VerificationKey StakeKey)
createStakeDelegatorCredentials dir = do
  liftIO $ createDirectoryIfMissing True dir
  (pvk, _psk) <- firstExceptT GenesisCmdAddressCmdError $ generateAndWriteKeyFiles desiredKeyOutputFormat AsPaymentKey paymentVK paymentSK
  (svk, _ssk) <- firstExceptT GenesisCmdStakeAddressCmdError $ runStakeAddressKeyGenCmd desiredKeyOutputFormat stakingVK stakingSK
  return (pvk, svk)
  where
    paymentVK = File @(VerificationKey ()) $ dir </> "payment.vkey"
    paymentSK = File @(SigningKey ()) $ dir </> "payment.skey"
    stakingVK = File @(VerificationKey ()) $ dir </> "staking.vkey"
    stakingSK = File @(SigningKey ()) $ dir </> "staking.skey"


createUtxoKeys :: FilePath -> ExceptT GenesisCmdError IO ()
createUtxoKeys dir = do
  liftIO $ createDirectoryIfMissing True dir
  runGenesisKeyGenUTxOCmd
    Cmd.GenesisKeyGenUTxOCmdArgs
    { Cmd.verificationKeyPath = File @(VerificationKey ()) $ dir </> "utxo.vkey"
    , Cmd.signingKeyPath = File @(SigningKey ()) $ dir </> "utxo.skey"
    }

createPoolCredentials :: KeyOutputFormat -> FilePath -> ExceptT GenesisCmdError IO ()
createPoolCredentials fmt dir = do
  liftIO $ createDirectoryIfMissing True dir
  firstExceptT GenesisCmdNodeCmdError $ do
    runNodeKeyGenKesCmd $ Cmd.NodeKeyGenKESCmdArgs
        fmt
        (onlyOut kesVK)
        (File @(SigningKey ()) $ dir </> "kes.skey")
    runNodeKeyGenVrfCmd $ Cmd.NodeKeyGenVRFCmdArgs
        fmt
        (File @(VerificationKey ()) $ dir </> "vrf.vkey")
        (File @(SigningKey ()) $ dir </> "vrf.skey")
    runNodeKeyGenColdCmd $ Cmd.NodeKeyGenColdCmdArgs
        fmt
        (File @(VerificationKey ()) $ dir </> "cold.vkey")
        (onlyOut coldSK)
        (onlyOut opCertCtr)
    runNodeIssueOpCertCmd $ Cmd.NodeIssueOpCertCmdArgs
        (VerificationKeyFilePath (onlyIn kesVK))
        (onlyIn coldSK)
        opCertCtr
        (KESPeriod 0)
        (File $ dir </> "opcert.cert")
  firstExceptT GenesisCmdStakeAddressCmdError $
    void $ runStakeAddressKeyGenCmd
        fmt
        (File @(VerificationKey ()) $ dir </> "staking-reward.vkey")
        (File @(SigningKey ()) $ dir </> "staking-reward.skey")
 where
   kesVK = File @(VerificationKey ()) $ dir </> "kes.vkey"
   coldSK = File @(SigningKey ()) $ dir </> "cold.skey"
   opCertCtr = File $ dir </> "opcert.counter"

data Delegation = Delegation
  { dInitialUtxoAddr  :: !(AddressInEra ShelleyEra)
  , dDelegStaking     :: !(L.KeyHash L.Staking L.StandardCrypto)
  , dPoolParams       :: !(L.PoolParams L.StandardCrypto)
  }
  deriving (Generic, NFData)

buildPoolParams
  :: NetworkId
  -> FilePath -- ^ File directory where the necessary pool credentials were created
  -> Word -- ^ The index of the pool being built. Starts at 0.
  -> Map Word [L.StakePoolRelay] -- ^ User submitted stake pool relay map. Starts at 0
  -> ExceptT GenesisCmdError IO (L.PoolParams L.StandardCrypto)
buildPoolParams nw dir index specifiedRelays = do
    StakePoolVerificationKey poolColdVK
      <- firstExceptT (GenesisCmdStakePoolCmdError . StakePoolCmdReadFileError)
           . newExceptT $ readFileTextEnvelope (AsVerificationKey AsStakePoolKey) poolColdVKF

    VrfVerificationKey poolVrfVK
      <- firstExceptT (GenesisCmdNodeCmdError . NodeCmdReadFileError)
           . newExceptT $ readFileTextEnvelope (AsVerificationKey AsVrfKey) poolVrfVKF
    rewardsSVK
      <- firstExceptT GenesisCmdTextEnvReadFileError
           . newExceptT $ readFileTextEnvelope (AsVerificationKey AsStakeKey) poolRewardVKF

    pure L.PoolParams
      { L.ppId          = L.hashKey poolColdVK
      , L.ppVrf         = L.hashVerKeyVRF poolVrfVK
      , L.ppPledge      = L.Coin 0
      , L.ppCost        = L.Coin 0
      , L.ppMargin      = minBound
      , L.ppRewardAcnt  =
          toShelleyStakeAddr $ makeStakeAddress nw $ StakeCredentialByKey (verificationKeyHash rewardsSVK)
      , L.ppOwners      = mempty
      , L.ppRelays      = lookupPoolRelay specifiedRelays
      , L.ppMetadata    = L.SNothing
      }
 where
   lookupPoolRelay :: Map Word [L.StakePoolRelay] -> Seq.StrictSeq L.StakePoolRelay
   lookupPoolRelay m = Seq.fromList $ Map.findWithDefault [] index m
   poolColdVKF = File $ dir </> "cold.vkey"
   poolVrfVKF = File $ dir </> "vrf.vkey"
   poolRewardVKF = File $ dir </> "staking-reward.vkey"

-- | This function should only be used for testing purposes.
-- Keys returned by this function are not cryptographically secure.
computeInsecureStakeKeyAddr
  :: StdGen
  -> IO (StdGen, (VerificationKey PaymentKey, VerificationKey StakeKey))
computeInsecureStakeKeyAddr g0 = do
    (paymentKeys, g1) <- first getVerificationKey <$> generateInsecureSigningKey g0 AsPaymentKey
    (stakeKeys  , g2) <- first getVerificationKey <$> generateInsecureSigningKey g1 AsStakeKey
    return (g2, (paymentKeys, stakeKeys))

computeDelegation
  :: NetworkId
  -> (VerificationKey PaymentKey, VerificationKey StakeKey)
  -> L.PoolParams L.StandardCrypto
  -> Delegation
computeDelegation nw (paymentVK, stakeVK) dPoolParams = do
    let paymentCredential = PaymentCredentialByKey (verificationKeyHash paymentVK)
    let stakeAddressReference = StakeAddressByValue . StakeCredentialByKey . verificationKeyHash $ stakeVK
    Delegation
      { dInitialUtxoAddr = makeShelleyAddressInEra ShelleyBasedEraShelley nw paymentCredential stakeAddressReference
      , dDelegStaking = L.hashKey $ unStakeVerificationKey stakeVK
      , dPoolParams
      }

updateOutputTemplate
  :: forall m. MonadError GenesisCmdError m
  => SystemStart -- ^ System start time
  -> Map (Hash GenesisKey) (Hash GenesisDelegateKey, Hash VrfKey) -- ^ Genesis delegation (not stake-based)
  -> Maybe L.Coin -- ^ Total amount of lovelace
  -> [AddressInEra ShelleyEra] -- ^ UTxO addresses that are not delegating
  -> [(L.KeyHash 'L.StakePool L.StandardCrypto, L.PoolParams L.StandardCrypto)] -- ^ Pool map
  -> [(L.KeyHash 'L.Staking L.StandardCrypto, L.KeyHash 'L.StakePool L.StandardCrypto)] -- ^ Delegaton map
  -> Maybe L.Coin -- ^ Amount of lovelace to delegate
  -> Int -- ^ Number of UTxO address for delegation
  -> [AddressInEra ShelleyEra] -- ^ UTxO address for delegation
  -> [AddressInEra ShelleyEra] -- ^ Stuffed UTxO addresses
  -> ShelleyGenesis L.StandardCrypto -- ^ Template from which to build a genesis
  -> m (ShelleyGenesis L.StandardCrypto) -- ^ Updated genesis
updateOutputTemplate
  (SystemStart sgSystemStart)
  genDelegMap mTotalSupply utxoAddrsNonDeleg pools stake
  mDelegatedSupply
  nUtxoAddrsDeleg utxoAddrsDeleg stuffedUtxoAddrs
  template@ShelleyGenesis{ sgProtocolParams } = do
    when (delegCoinRaw > totalSupply) (throwError $ GenesisCmdDelegatedSupplyExceedsTotalSupply delegCoinRaw totalSupply)
    pure template
          { sgSystemStart
          , sgMaxLovelaceSupply = totalSupply
          , sgGenDelegs = shelleyDelKeys
          , sgInitialFunds = ListMap.fromList
                              [ (toShelleyAddr addr, v)
                              | (addr, v) <-
                                distribute nonDelegCoin nUtxoAddrsNonDeleg utxoAddrsNonDeleg
                                ++ distribute delegCoin nUtxoAddrsDeleg utxoAddrsDeleg
                                ++ mkStuffedUtxo stuffedUtxoAddrs
                              ]
          , sgStaking =
            ShelleyGenesisStaking
              { sgsPools = ListMap pools
              , sgsStake = ListMap stake
              }
          , sgProtocolParams
          }
  where
    nonDelegCoin = getCoinForDistribution nonDelegCoinRaw
    delegCoin = getCoinForDistribution delegCoinRaw

    getCoinForDistribution :: Integer -> Natural
    getCoinForDistribution inputCoin =
      -- If the initial funds are equal to the maximum funds, rewards cannot be created.
      -- So subtrahend a part for the treasury:
      fromInteger $ inputCoin - (inputCoin `quot` 10)

    nUtxoAddrsNonDeleg  = length utxoAddrsNonDeleg
    maximumLovelaceSupply :: Word64
    maximumLovelaceSupply = sgMaxLovelaceSupply template

    totalSupply :: Integral a => a
    -- if --total-supply is not specified, supply comes from the template passed to this function:
    totalSupply = fromIntegral $ maybe maximumLovelaceSupply unLovelace mTotalSupply

    delegCoinRaw, nonDelegCoinRaw :: Integer
    delegCoinRaw = maybe 0 unLovelace mDelegatedSupply
    -- Since the user can specify total supply and delegated amount, the non-delegated amount is:
    nonDelegCoinRaw = totalSupply - delegCoinRaw

    distribute :: Natural -> Int -> [AddressInEra ShelleyEra] -> [(AddressInEra ShelleyEra, L.Coin)]
    distribute funds nAddrs addrs =
      zip addrs $ L.Coin . toInteger <$> (coinPerAddr + remainder:repeat coinPerAddr)
      where coinPerAddr, remainder :: Natural
            (coinPerAddr, remainder) = funds `divMod` fromIntegral nAddrs

    mkStuffedUtxo :: [AddressInEra ShelleyEra] -> [(AddressInEra ShelleyEra, L.Coin)]
    mkStuffedUtxo xs = (, L.Coin minUtxoVal) <$> xs
      where L.Coin minUtxoVal = sgProtocolParams ^. L.ppMinUTxOValueL
    shelleyDelKeys = Map.fromList
      [ (gh, L.GenDelegPair gdh h)
      | (GenesisKeyHash gh,
          (GenesisDelegateKeyHash gdh, VrfKeyHash h)) <- Map.toList genDelegMap
      ]

    unLovelace :: Integral a => L.Coin -> a
    unLovelace (L.Coin coin) = fromIntegral coin

maybeReadAndDecodeGenesisFileSpec :: (FromJSON a) => Maybe FilePath -> a -> ExceptT GenesisCmdError IO a
maybeReadAndDecodeGenesisFileSpec spec defaultSpec =
  case spec of
    Just specPath ->
      newExceptT $ readAndDecodeGenesisFile specPath
    Nothing ->
      -- No template given: a default file is created
      pure defaultSpec

readAndDecodeGenesisFile :: (FromJSON a) => FilePath -> IO (Either GenesisCmdError a)
readAndDecodeGenesisFile fpath = runExceptT $ do
  lbs <- handleIOExceptT (GenesisCmdGenesisFileReadError . FileIOError fpath) $ LBS.readFile fpath
  firstExceptT (GenesisCmdGenesisFileDecodeError fpath . Text.pack)
    . hoistEither $ Aeson.eitherDecode' lbs

-- @readRelays fp@ reads the relays specification from a file
readRelays :: ()
  => MonadIO m
  => FilePath -- ^ The file to read from
  -> ExceptT GenesisCmdError m (Map Word [L.StakePoolRelay])
readRelays fp = do
  relaySpecJsonBs <-
    handleIOExceptT (GenesisCmdStakePoolRelayFileError fp) (LBS.readFile fp)
  firstExceptT (GenesisCmdStakePoolRelayJsonDecodeError fp)
    . hoistEither $ Aeson.eitherDecode relaySpecJsonBs

-- | Current UTCTime plus 30 seconds
getCurrentTimePlus30 :: ExceptT a IO UTCTime
getCurrentTimePlus30 =
    plus30sec <$> liftIO getCurrentTime
  where
    plus30sec :: UTCTime -> UTCTime
    plus30sec = addUTCTime (30 :: NominalDiffTime)

readGenDelegsMap :: Map Int FilePath
                 -> Map Int FilePath
                 -> Map Int FilePath
                 -> ExceptT GenesisCmdError IO
                            (Map (Hash GenesisKey)
                                 (Hash GenesisDelegateKey, Hash VrfKey))
readGenDelegsMap genesisKeys delegateKeys delegateVrfKeys = do
    gkm <- readKeys (AsVerificationKey AsGenesisKey) genesisKeys
    dkm <- readKeys (AsVerificationKey AsGenesisDelegateKey) delegateKeys
    vkm <- readKeys (AsVerificationKey AsVrfKey) delegateVrfKeys

    let combinedMap :: Map Int (VerificationKey GenesisKey,
                                (VerificationKey GenesisDelegateKey,
                                 VerificationKey VrfKey))
        combinedMap =
          Map.intersectionWith (,)
            gkm
            (Map.intersectionWith (,) dkm vkm)

    -- All the maps should have an identical set of keys. Complain if not.
    let gkmExtra = gkm Map.\\ combinedMap
        dkmExtra = dkm Map.\\ combinedMap
        vkmExtra = vkm Map.\\ combinedMap
    unless (Map.null gkmExtra && Map.null dkmExtra && Map.null vkmExtra) $
      throwError $ GenesisCmdMismatchedGenesisKeyFiles
                     (Map.keys gkm) (Map.keys dkm) (Map.keys vkm)

    let delegsMap :: Map (Hash GenesisKey)
                         (Hash GenesisDelegateKey, Hash VrfKey)
        delegsMap =
          Map.fromList [ (gh, (dh, vh))
                       | (g,(d,v)) <- Map.elems combinedMap
                       , let gh = verificationKeyHash g
                             dh = verificationKeyHash d
                             vh = verificationKeyHash v
                       ]

    pure delegsMap


-- | Given a map @{0 -> someKey0, 1 -> someKey1}@, lift reading
-- the files to the map's values.
readKeys :: ()
  => HasTextEnvelope a
  => Ord k
  => AsType a
  -> Map k FilePath
  -> ExceptT GenesisCmdError IO (Map k a)
readKeys asType genesisVKeys = do
  firstExceptT GenesisCmdTextEnvReadFileError $
    Map.fromList <$>
      sequence
        [ (,) ix <$> readKey (File file)
        | (ix, file) <- toList genesisVKeys ]
  where
    readKey = newExceptT . readFileTextEnvelope asType


readInitialFundAddresses :: [FilePath] -> NetworkId
                         -> ExceptT GenesisCmdError IO [AddressInEra ShelleyEra]
readInitialFundAddresses utxoKeyFileNames nw = do
    vkeys <- firstExceptT GenesisCmdTextEnvReadFileError $
               sequence
                 [ newExceptT $
                     readFileTextEnvelope (AsVerificationKey AsGenesisUTxOKey)
                                          (File file)
                 | file <- utxoKeyFileNames ]
    return [ addr | vkey <- vkeys
           , let vkh  = verificationKeyHash (castVerificationKey vkey)
                 addr = makeShelleyAddressInEra ShelleyBasedEraShelley nw (PaymentCredentialByKey vkh)
                                                NoStakeAddress
           ]
