module App.Fossa.LicenseScan (
  licenseScanSubCommand,
) where

import App.Fossa.Config.LicenseScan (
  LicenseScanCommand,
  LicenseScanConfig (..),
  mkSubCommand,
 )
import App.Fossa.EmbeddedBinary (withThemisAndIndex)
import App.Fossa.LicenseScanner (dedupVendoredDeps, scanVendoredDep)
import App.Fossa.ManualDeps (
  ManualDependencies (vendoredDependencies),
  VendoredDependency,
  findFossaDepsFile,
  readFoundDeps,
 )
import App.Fossa.RunThemis (execRawThemis)
import App.Fossa.Subcommand (SubCommand)
import App.Types (BaseDir (BaseDir))
import Control.Carrier.StickyLogger (
  Has,
  StickyLogger,
  runStickyLogger,
 )
import Control.Effect.Diagnostics (Diagnostics, ToDiagnostic, fromMaybe)
import Control.Effect.Lift (Lift)
import Data.Aeson (KeyValue ((.=)), ToJSON (toJSON), object)
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.String.Conversion (decodeUtf8)
import Diag.Diagnostic (ToDiagnostic (renderDiagnostic))
import Effect.Exec (Exec)
import Effect.Logger (Logger, Severity (SevInfo), logStdout)
import Effect.ReadFS (ReadFS)
import Path (Abs, Dir, Path)
import Prettyprinter (vsep)
import Srclib.Types (LicenseSourceUnit)

data MissingFossaDepsFile = MissingFossaDepsFile
data NoVendoredDeps = NoVendoredDeps

instance ToDiagnostic MissingFossaDepsFile where
  renderDiagnostic _ =
    vsep
      [ "'fossa experimental-license-scan fossa-deps' requires pointing to a directory with a fossa-deps file."
      , "The file can have one of the extensions: .yaml .yml .json"
      ]

instance ToDiagnostic NoVendoredDeps where
  renderDiagnostic _ = "The 'vendored-dependencies' section of the fossa deps file is empty or missing."

newtype UploadUnits = UploadUnits (NonEmpty LicenseSourceUnit)

instance ToJSON UploadUnits where
  toJSON (UploadUnits units) = object ["uploadUnits" .= units]

licenseScanSubCommand :: SubCommand LicenseScanCommand LicenseScanConfig
licenseScanSubCommand = mkSubCommand licenseScanMain

licenseScanMain ::
  ( Has (Lift IO) sig m
  , Has Exec sig m
  , Has Diagnostics sig m
  , Has ReadFS sig m
  , Has Logger sig m
  ) =>
  LicenseScanConfig ->
  m ()
licenseScanMain = \case
  RawPathScan (BaseDir dir) -> logStdout . decodeUtf8 =<< withThemisAndIndex (`execRawThemis` dir)
  VendoredDepsOutput basedir -> outputVendoredDeps basedir

outputVendoredDeps ::
  ( Has Diagnostics sig m
  , Has ReadFS sig m
  , Has Logger sig m
  , Has (Lift IO) sig m
  , Has Exec sig m
  ) =>
  BaseDir ->
  m ()
outputVendoredDeps (BaseDir dir) = runStickyLogger SevInfo $ do
  manualDepsFile <- fromMaybe MissingFossaDepsFile =<< findFossaDepsFile dir
  manualDeps <- readFoundDeps manualDepsFile
  vendoredDeps <- fromMaybe NoVendoredDeps $ NE.nonEmpty $ vendoredDependencies manualDeps
  resultMap <- UploadUnits <$> runLicenseScan dir vendoredDeps
  logStdout . decodeUtf8 $ Aeson.encode resultMap

runLicenseScan ::
  ( Has Diagnostics sig m
  , Has ReadFS sig m
  , Has StickyLogger sig m
  , Has (Lift IO) sig m
  , Has Exec sig m
  ) =>
  Path Abs Dir ->
  NonEmpty VendoredDependency ->
  m (NonEmpty LicenseSourceUnit)
runLicenseScan basedir vdeps = dedupVendoredDeps vdeps >>= traverse (scanVendoredDep basedir)
