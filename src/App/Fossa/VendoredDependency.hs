{-# LANGUAGE RecordWildCards #-}

module App.Fossa.VendoredDependency (
  VendoredDependency (..),
  VendoredDependencyScanMode (..),
  arcToLocator,
  vendoredDepToLocator,
  forceVendoredToArchive,
  compressFile,
  hashFile,
  dedupVendoredDeps,
  skippedDepsDebugLog,
  SkippableDeps (..),
  NeedScanningDeps (..),
  SkippedDepsLogMsg (..),
) where

import Codec.Archive.Tar qualified as Tar
import Codec.Compression.GZip qualified as GZip
import Control.Algebra (Has)
import Control.Carrier.Diagnostics (Diagnostics, fatalText)
import Crypto.Hash (Digest, MD5, hashlazy)
import Data.Aeson (FromJSON (parseJSON), withObject, (.:), (.:?))
import Data.Aeson.Extra (TextLike (unTextLike), forbidMembers)
import Data.ByteString.Lazy qualified as BS
import Data.Functor.Extra ((<$$>))
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.String.Conversion (
  ToString (toString),
  ToText (toText),
 )
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID.V4 (nextRandom)
import Fossa.API.Types (Archive (..))
import Path (Abs, Dir, Path)
import Prettyprinter (Pretty (pretty), vsep)
import Srclib.Types (Locator (..))
import System.FilePath.Posix (splitDirectories, (</>))

data VendoredDependency = VendoredDependency
  { vendoredName :: Text
  , vendoredPath :: Text
  , vendoredVersion :: Maybe Text
  }
  deriving (Eq, Ord, Show)

instance FromJSON VendoredDependency where
  parseJSON = withObject "VendoredDependency" $ \obj ->
    VendoredDependency
      <$> obj .: "name"
      <*> obj .: "path"
      <*> (unTextLike <$$> obj .:? "version")
      <* forbidMembers "vendored dependencies" ["type", "license", "url", "description"] obj
data VendoredDependencyScanMode
  = SkipPreviouslyScanned
  | SkippingNotSupported
  | SkippingDisabledViaFlag
  deriving (Eq, Ord, Show)

newtype NeedScanningDeps = NeedScanningDeps {needScanningDeps :: [VendoredDependency]}
  deriving (Eq, Ord, Show)

newtype SkippableDeps = SkippableDeps {skippableDeps :: [VendoredDependency]}
  deriving (Eq, Ord, Show)

-- Debug logs giving info about which vendored deps were actually scanned
data SkippedDepsLogMsg
  = SkippingUnsupportedMsg
  | SkippingDisabledViaFlagMsg
  | AllDepsPreviouslyScannedMsg
  | AllDepsNeedScanningMsg
  | SomeDepsNeedScanningMsg SkippableDeps
  deriving (Eq, Ord, Show)

instance Pretty SkippedDepsLogMsg where
  pretty SkippingUnsupportedMsg =
    vsep
      [ "This version of the FOSSA service does not support enumerating previously scanned vendored dependencies."
      , "Performing a full scan of all vendored dependencies even if they have been scanned previously."
      ]
  pretty SkippingDisabledViaFlagMsg =
    "Vendored dependency rescans forced on via either the --force-vendored-dependency-rescans flag or the vendoredDependencies.forceRescans entry in .fossa.yml, so performing a full scan of all vendored dependencies even if they have been scanned previously."
  pretty AllDepsPreviouslyScannedMsg =
    "All of the current vendored dependencies have been previously scanned, reusing previous results."
  pretty AllDepsNeedScanningMsg =
    "None of the current vendored dependencies have been previously scanned. License scanning all vendored dependencies"
  pretty (SomeDepsNeedScanningMsg skippedDeps) =
    vsep
      [ "Some of the current vendored dependencies have already been scanned by FOSSA."
      , "Reusing previous results for the following vendored dependencies: " <> (pretty . show $ skippedDeps)
      ]

dedupVendoredDeps :: (Has Diagnostics sig m) => NonEmpty VendoredDependency -> m (NonEmpty VendoredDependency)
dedupVendoredDeps vdeps = do
  -- Users with many instances of vendored dependencies may accidentally have complete duplicates. Remove them.
  let uniqDeps = NE.nub vdeps
  let duplicates = duplicateNames uniqDeps
  case duplicates of
    [] -> pure uniqDeps
    -- However, users may also have vendored dependencies that have duplicate names but are not complete duplicates.
    -- These aren't valid and can't be automatically handled, so fail the scan with them.
    dups -> fatalText $ duplicateFailureBundle dups

-- | List of names that occur more than once in a list of vendored dependencies.
duplicateNames :: NonEmpty VendoredDependency -> [Text]
duplicateNames = Map.keys . Map.filter (> 1) . Map.fromListWith (+) . map pair . NonEmpty.toList
  where
    pair :: VendoredDependency -> (Text, Int)
    pair VendoredDependency{vendoredName} = (vendoredName, 1)

duplicateFailureBundle :: [Text] -> Text
duplicateFailureBundle names =
  "The provided vendored dependencies contain the following duplicate names:\n\t"
    <> Text.intercalate "\n\t" names
    <> "\n\n"
    <> "Vendored dependency entries may not specify duplicate names.\n"
    <> "Please ensure that each vendored dependency entry has a unique name."

forceVendoredToArchive :: VendoredDependency -> Archive
forceVendoredToArchive dep = Archive (vendoredName dep) (fromMaybe "" $ vendoredVersion dep)

arcToLocator :: Archive -> Locator
arcToLocator arc =
  Locator
    { locatorFetcher = "archive"
    , locatorProject = archiveName arc
    , locatorRevision = Just $ archiveVersion arc
    }

vendoredDepToLocator :: VendoredDependency -> Locator
vendoredDepToLocator VendoredDependency{..} =
  Locator{locatorFetcher = "archive", locatorProject = vendoredName, locatorRevision = vendoredVersion}

compressFile :: Path Abs Dir -> Path Abs Dir -> FilePath -> IO FilePath
compressFile outputDir directory fileToTar = do
  -- We are adding the suffix to avoid errors when we compress to a path that already exists
  -- This is most likely to happen if `fileToTar` is "."
  suffix <- nextRandom
  let finalFilename = fileToTar ++ show suffix
  let finalFile = toString outputDir </> safeSeparators finalFilename
  entries <- Tar.pack (toString directory) [fileToTar]
  BS.writeFile finalFile $ GZip.compress $ Tar.write entries
  pure finalFile

md5 :: BS.ByteString -> Digest MD5
md5 = hashlazy

hashFile :: FilePath -> IO Text
hashFile fileToHash = do
  fileContent <- BS.readFile fileToHash
  pure . toText . show $ md5 fileContent

safeSeparators :: FilePath -> FilePath
safeSeparators = intercalate "_" . splitDirectories

skippedDepsDebugLog :: NeedScanningDeps -> SkippableDeps -> VendoredDependencyScanMode -> SkippedDepsLogMsg
skippedDepsDebugLog needScanningDeps skippedDeps scanMode =
  case (needScanningDeps, scanMode) of
    (_, SkippingNotSupported) -> SkippingUnsupportedMsg
    (_, SkippingDisabledViaFlag) -> SkippingDisabledViaFlagMsg
    (NeedScanningDeps [], SkipPreviouslyScanned) -> AllDepsPreviouslyScannedMsg
    (_, SkipPreviouslyScanned) -> do
      case skippedDeps of
        SkippableDeps [] -> AllDepsNeedScanningMsg
        _ -> SomeDepsNeedScanningMsg skippedDeps
