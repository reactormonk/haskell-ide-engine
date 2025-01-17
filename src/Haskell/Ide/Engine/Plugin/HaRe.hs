{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Haskell.Ide.Engine.Plugin.HaRe where

import           Control.Lens.Operators
import           Control.Monad.State
-- import           Control.Monad.Trans.Control
import           Data.Aeson
import qualified Data.Aeson.Types                             as J
import           Data.Algorithm.Diff
import           Data.Algorithm.DiffOutput
import           Data.Foldable
import qualified Data.Text                                    as T
import qualified Data.Text.IO                                 as T
import           Exception
import           GHC.Generics                                 (Generic)
import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import qualified Haskell.Ide.Engine.Support.HieExtras         as Hie
import           Language.Haskell.GHC.ExactPrint.Print
import qualified Language.Haskell.LSP.Core                    as Core
import           Language.Haskell.LSP.VFS
import qualified Language.Haskell.LSP.Types                   as J
import qualified Language.Haskell.LSP.Types.Lens              as J
import           Language.Haskell.Refact.API                  hiding (logm)
import           Language.Haskell.Refact.HaRe
import           Language.Haskell.Refact.Utils.Monad          hiding (logm)
import qualified Data.Rope.UTF16 as Rope


-- ---------------------------------------------------------------------
hareDescriptor :: PluginId -> PluginDescriptor
hareDescriptor plId = PluginDescriptor
  { pluginId = plId
  , pluginName = "HaRe"
  , pluginDesc = "A Haskell 2010 refactoring tool. HaRe supports the full "
              <> "Haskell 2010 standard, through making use of the GHC API.  HaRe attempts to "
              <> "operate in a safe way, by first writing new files with proposed changes, and "
              <> "only swapping these with the originals when the change is accepted. "
  , pluginCommands =
      [ PluginCommand "demote" "Move a definition one level down"
          demoteCmd
      , PluginCommand "dupdef" "Duplicate a definition"
          dupdefCmd
      , PluginCommand "iftocase" "Converts an if statement to a case statement"
          iftocaseCmd
      , PluginCommand "liftonelevel" "Move a definition one level up from where it is now"
          liftonelevelCmd
      , PluginCommand "lifttotoplevel" "Move a definition to the top level from where it is now"
          lifttotoplevelCmd
      , PluginCommand "rename" "rename a variable or type"
          renameCmd
      , PluginCommand "deletedef" "Delete a definition"
          deleteDefCmd
      , PluginCommand "genapplicative" "Generalise a monadic function to use applicative"
          genApplicativeCommand

      ]
  , pluginCodeActionProvider = Just codeActionProvider
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider = Nothing
  , pluginSymbolProvider = Nothing
  , pluginFormattingProvider = Nothing
  }

-- ---------------------------------------------------------------------

data HarePointWithText =
  HPT { hptFile :: Uri
      , hptPos  :: Position
      , hptText :: T.Text
      } deriving (Eq,Generic,Show)

instance FromJSON HarePointWithText where
  parseJSON = genericParseJSON $ Hie.customOptions 3
instance ToJSON HarePointWithText where
  toJSON = genericToJSON $ Hie.customOptions 3

data HareRange =
  HR { hrFile     :: Uri
     , hrStartPos :: Position
     , hrEndPos   :: Position
     } deriving (Eq,Generic,Show)

instance FromJSON HareRange where
  parseJSON = genericParseJSON $ Hie.customOptions 2
instance ToJSON HareRange where
  toJSON = genericToJSON $ Hie.customOptions 2

-- ---------------------------------------------------------------------

demoteCmd :: CommandFunc Hie.HarePoint WorkspaceEdit
demoteCmd  = CmdSync $ \(Hie.HP uri pos) ->
  demoteCmd' uri pos

demoteCmd' :: Uri -> Position -> IdeGhcM (IdeResult WorkspaceEdit)
demoteCmd' uri pos =
  pluginGetFile "demote: " uri $ \file ->
    runHareCommand "demote" (compDemote file (unPos pos))

-- compDemote :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

dupdefCmd :: CommandFunc HarePointWithText WorkspaceEdit
dupdefCmd = CmdSync $ \(HPT uri pos name) ->
  dupdefCmd' uri pos name

dupdefCmd' :: Uri -> Position -> T.Text -> IdeGhcM (IdeResult WorkspaceEdit)
dupdefCmd' uri pos name =
  pluginGetFile "dupdef: " uri $ \file ->
    runHareCommand  "dupdef" (compDuplicateDef file (T.unpack name) (unPos pos))

-- compDuplicateDef :: FilePath -> String -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

iftocaseCmd :: CommandFunc HareRange WorkspaceEdit
iftocaseCmd = CmdSync $ \(HR uri startPos endPos) ->
  iftocaseCmd' uri (Range startPos endPos)

iftocaseCmd' :: Uri -> Range -> IdeGhcM (IdeResult WorkspaceEdit)
iftocaseCmd' uri (Range startPos endPos) =
  pluginGetFile "iftocase: " uri $ \file ->
    runHareCommand "iftocase" (compIfToCase file (unPos startPos) (unPos endPos))

-- compIfToCase :: FilePath -> SimpPos -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

liftonelevelCmd :: CommandFunc Hie.HarePoint WorkspaceEdit
liftonelevelCmd = CmdSync $ \(Hie.HP uri pos) ->
  liftonelevelCmd' uri pos

liftonelevelCmd' :: Uri -> Position -> IdeGhcM (IdeResult WorkspaceEdit)
liftonelevelCmd' uri pos =
  pluginGetFile "liftonelevelCmd: " uri $ \file ->
    runHareCommand "liftonelevel" (compLiftOneLevel file (unPos pos))

-- compLiftOneLevel :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

lifttotoplevelCmd :: CommandFunc Hie.HarePoint WorkspaceEdit
lifttotoplevelCmd = CmdSync $ \(Hie.HP uri pos) ->
  lifttotoplevelCmd' uri pos

lifttotoplevelCmd' :: Uri -> Position -> IdeGhcM (IdeResult WorkspaceEdit)
lifttotoplevelCmd' uri pos =
  pluginGetFile "lifttotoplevelCmd: " uri $ \file ->
    runHareCommand "lifttotoplevel" (compLiftToTopLevel file (unPos pos))

-- compLiftToTopLevel :: FilePath -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

renameCmd :: CommandFunc HarePointWithText WorkspaceEdit
renameCmd = CmdSync $ \(HPT uri pos name) ->
  renameCmd' uri pos name

renameCmd' :: Uri -> Position -> T.Text -> IdeGhcM (IdeResult WorkspaceEdit)
renameCmd' uri pos name =
  pluginGetFile "rename: " uri $ \file ->
      runHareCommand "rename" (compRename file (T.unpack name) (unPos pos))

-- compRename :: FilePath -> String -> SimpPos -> IO [FilePath]

-- ---------------------------------------------------------------------

deleteDefCmd :: CommandFunc Hie.HarePoint WorkspaceEdit
deleteDefCmd  = CmdSync $ \(Hie.HP uri pos) ->
  deleteDefCmd' uri pos

deleteDefCmd' :: Uri -> Position -> IdeGhcM (IdeResult WorkspaceEdit)
deleteDefCmd' uri pos =
  pluginGetFile "deletedef: " uri $ \file ->
      runHareCommand "deltetedef" (compDeleteDef file (unPos pos))

-- compDeleteDef ::FilePath -> SimpPos -> RefactGhc [ApplyRefacResult]

-- ---------------------------------------------------------------------

genApplicativeCommand :: CommandFunc Hie.HarePoint WorkspaceEdit
genApplicativeCommand  = CmdSync $ \(Hie.HP uri pos) ->
  genApplicativeCommand' uri pos

genApplicativeCommand' :: Uri -> Position -> IdeGhcM (IdeResult WorkspaceEdit)
genApplicativeCommand' uri pos =
  pluginGetFile "genapplicative: " uri $ \file ->
      runHareCommand "genapplicative" (compGenApplicative file (unPos pos))


-- ---------------------------------------------------------------------

getRefactorResult :: [ApplyRefacResult] -> [(FilePath,T.Text)]
getRefactorResult = map getNewFile . filter fileModified
  where fileModified ((_,m),_) = m == RefacModified
        getNewFile ((file,_),(ann, parsed)) = (file, T.pack $ exactPrint parsed ann)

makeRefactorResult :: [(FilePath,T.Text)] -> IdeGhcM (IdeResult WorkspaceEdit)
makeRefactorResult changedFiles = do
  let
    diffOne :: (FilePath, T.Text) -> IdeGhcM (IdeResult WorkspaceEdit)
    diffOne (fp, newText) = do
      uri <- canonicalizeUri $ filePathToUri fp
      mvf <- getVirtualFile uri

      origTextResult <- case mvf of
        Nothing -> do
          let defaultResult = do
                debugm "makeRefactorResult: no access to the persisted file."
                return $ IdeResultOk mempty

          withMappedFile fp defaultResult (fmap IdeResultOk . liftIO . T.readFile)
        Just vf -> return $ IdeResultOk $ Rope.toText $ _text vf

      case origTextResult of
        IdeResultFail err -> do
          logm "makeRefactorResult:could not retrieve original text"
          return $ IdeResultFail err
        IdeResultOk origText -> do
          -- TODO: remove this logging once we are sure we have a working solution
          logm $ "makeRefactorResult:groupedDiff = " ++ show (getGroupedDiff (lines $ T.unpack origText) (lines $ T.unpack newText))
          logm $ "makeRefactorResult:diffops = " ++ show (diffToLineRanges $ getGroupedDiff (lines $ T.unpack origText) (lines $ T.unpack newText))
          liftToGhc $ IdeResultOk <$> diffText (filePathToUri fp, origText) newText IncludeDeletions

  diffResults <- mapM diffOne changedFiles
  let diffs = sequenceA diffResults
  case diffs of
    IdeResultOk diffs' -> return $ IdeResultOk $ Core.reverseSortEdit $ fold diffs'
    IdeResultFail err -> return $ IdeResultFail err

-- ---------------------------------------------------------------------

runHareCommand :: String -> RefactGhc [ApplyRefacResult]
                 -> IdeGhcM (IdeResult WorkspaceEdit)
runHareCommand name cmd = do
     eitherRes <- runHareCommand' cmd
     case eitherRes of
       Left err ->
         pure (IdeResultFail
                 (IdeError PluginError
                           (T.pack $ name <> ": \"" <> err <> "\"")
                           Null))
       Right res -> do
            let changes = getRefactorResult res
            makeRefactorResult changes

-- ---------------------------------------------------------------------

-- newtype RefactGhc a = RefactGhc
--     { unRefactGhc :: StateT RefactState HIE.IdeGhcM a
--     }

runHareCommand' :: forall a. RefactGhc a
                 -> IdeGhcM (Either String a)
runHareCommand' cmd =
  do let initialState =
           -- TODO: Make this a command line flag
           RefSt {rsSettings = defaultSettings
           -- RefSt {rsSettings = logSettings
                 ,rsUniqState = 1
                 ,rsSrcSpanCol = 1
                 ,rsFlags = RefFlags False
                 ,rsStorage = StorageNone
                 ,rsCurrentTarget = Nothing
                 ,rsModule = Nothing}
     let
         cmd' :: StateT RefactState IdeGhcM a
         cmd' = unRefactGhc cmd
         embeddedCmd =
           evalStateT cmd' initialState
         handlers
           :: Applicative m
           => [ErrorHandler m (Either String a)]
         handlers =
           [ErrorHandler (\(ErrorCall e) -> pure (Left e))]
     fmap Right embeddedCmd `gcatches` handlers


-- ---------------------------------------------------------------------

codeActionProvider :: CodeActionProvider
codeActionProvider pId docId (J.Range pos _) _ =
  pluginGetFile "HaRe codeActionProvider: " (docId ^. J.uri) $ \file ->
    ifCachedInfo file (IdeResultOk mempty) $ \info ->
      case getArtifactsAtPos pos (defMap info) of
        [h] -> do
          let name = Hie.showName $ snd h
          debugm $ show name
          IdeResultOk <$> sequence [
              mkAction "liftonelevel"
                J.CodeActionRefactorExtract $ "Lift " <> name <> " one level"
            , mkAction "lifttotoplevel"
                J.CodeActionRefactorExtract $ "Lift " <> name <> " to top level"
            , mkAction "demote"
                J.CodeActionRefactorInline $ "Demote " <> name <> " one level"
            , mkAction "deletedef"
                J.CodeActionRefactor $ "Delete definition of " <> name
            , mkHptAction "dupdef"
                J.CodeActionRefactor "Duplicate definition of " name
            ]
        _   -> case getArtifactsAtPos pos (locMap info) of
              -- TODO: disabled casesplit command
              -- TODO: @fendor: add github issue link
              --  [h] -> do
              --   let name = Hie.showName $ snd h
              --   IdeResultOk <$> sequence [
              --       mkAction "casesplit"
              --         J.CodeActionRefactorRewrite $ "Case split on " <> name
              --     ]
               _   -> return $ IdeResultOk []
  where
    mkAction aId kind title = do
      let args = [J.toJSON $ Hie.HP (docId ^. J.uri) pos]
      cmd <- mkLspCommand pId aId title (Just args)
      return $ J.CodeAction title (Just kind) mempty Nothing (Just cmd)

    mkHptAction aId kind title name = do
      let args = [J.toJSON $ HPT (docId ^. J.uri) pos (name <> "'")]
      cmd <- mkLspCommand pId aId title (Just args)
      return $ J.CodeAction (title <> name) (Just kind) mempty Nothing (Just cmd)
