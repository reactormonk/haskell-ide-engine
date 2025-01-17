{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeFamilies        #-}
-- Generic actions which require a typechecked module
module Haskell.Ide.Engine.Plugin.Generic where

import           Control.Lens hiding (cons, children)
import           Data.Aeson
import           Data.Function
import qualified Data.HashMap.Strict               as HM
import           Data.List
import           Data.Maybe
import           Data.Monoid ((<>))
import qualified Data.Text                         as T
import           Name
import           GHC.Generics
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import qualified Haskell.Ide.Engine.GhcCompat as C ( GhcPs )
import qualified Haskell.Ide.Engine.Support.HieExtras as Hie
import           Haskell.Ide.Engine.ArtifactMap
import qualified Language.Haskell.LSP.Types        as LSP
import qualified Language.Haskell.LSP.Types.Lens   as LSP
import           Language.Haskell.Refact.API       (hsNamessRdr)
import           HIE.Bios.Ghc.Doc

import           GHC
import           HscTypes
import           DataCon
import           TcRnTypes
import           Outputable hiding ((<>))
import           PprTyThing


-- ---------------------------------------------------------------------

genericDescriptor :: PluginId -> PluginDescriptor
genericDescriptor plId = PluginDescriptor
  { pluginId = plId
  , pluginName = "generic"
  , pluginDesc = "generic actions"
  , pluginCommands = [PluginCommand "type" "Get the type of the expression under (LINE,COL)" typeCmd]
  , pluginCodeActionProvider = Just codeActionProvider
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider = Just hoverProvider
  , pluginSymbolProvider = Just symbolProvider
  , pluginFormattingProvider = Nothing
  }

-- ---------------------------------------------------------------------

data TypeParams =
  TP { tpIncludeConstraints :: Bool
     , tpFile               :: Uri
     , tpPos                :: Position
     } deriving (Eq,Show,Generic)

instance FromJSON TypeParams where
  parseJSON = genericParseJSON customOptions
instance ToJSON TypeParams where
  toJSON = genericToJSON customOptions

typeCmd :: CommandFunc TypeParams [(Range,T.Text)]
typeCmd = CmdSync $ \(TP _bool uri pos) ->
  liftToGhc $ newTypeCmd pos uri

newTypeCmd :: Position -> Uri -> IdeM (IdeResult [(Range, T.Text)])
newTypeCmd newPos uri =
  pluginGetFile "newTypeCmd: " uri $ \fp ->
    ifCachedModule fp (IdeResultOk []) $ \tm info -> do
      debugm $ "newTypeCmd: " <> (show (newPos, uri))
      return $ IdeResultOk $ pureTypeCmd newPos tm info

pureTypeCmd :: Position -> GHC.TypecheckedModule -> CachedInfo -> [(Range,T.Text)]
pureTypeCmd newPos tm info =
    case mOldPos of
      Nothing -> []
      Just pos -> concatMap f (spanTypes pos)
  where
    mOldPos = newPosToOld info newPos
    typm = typeMap info
    spanTypes' pos = getArtifactsAtPos pos typm
    spanTypes pos = sortBy (cmp `on` fst) (spanTypes' pos)
    dflag = ms_hspp_opts $ pm_mod_summary $ tm_parsed_module tm
    unqual = mkPrintUnqualified dflag $ tcg_rdr_env $ fst $ tm_internals_ tm
    st = mkUserStyle dflag unqual AllTheWay

    f (range', t) =
      case oldRangeToNew info range' of
        (Just range) -> [(range , T.pack $ prettyTy st t)]
        _ -> []

    prettyTy stl
      = showOneLine dflag stl . pprTypeForUser

-- TODO: MP: Why is this defined here?
cmp :: Range -> Range -> Ordering
cmp a b
  | a `isSubRangeOf` b = LT
  | b `isSubRangeOf` a = GT
  | otherwise = EQ

isSubRangeOf :: Range -> Range -> Bool
isSubRangeOf (Range sa ea) (Range sb eb) = sb <= sa && eb >= ea

-- ---------------------------------------------------------------------
--
-- ---------------------------------------------------------------------

customOptions :: Options
customOptions = defaultOptions { fieldLabelModifier = camelTo2 '_' . drop 2}

data InfoParams =
  IP { ipFile :: Uri
     , ipExpr :: T.Text
     } deriving (Eq,Show,Generic)

instance FromJSON InfoParams where
  parseJSON = genericParseJSON customOptions
instance ToJSON InfoParams where
  toJSON = genericToJSON customOptions

newtype TypeDef = TypeDef T.Text deriving (Eq, Show)

data FunctionSig =
  FunctionSig { fsName :: !T.Text
              , fsType :: !TypeDef
              } deriving (Eq, Show)

newtype ValidSubstitutions = ValidSubstitutions [FunctionSig] deriving (Eq, Show)

newtype Bindings = Bindings [FunctionSig] deriving (Eq, Show)

data TypedHoles =
  TypedHoles { thDiag :: LSP.Diagnostic
             , thWant :: TypeDef
             , thSubstitutions :: ValidSubstitutions
             , thBindings :: Bindings
             } deriving (Eq, Show)

codeActionProvider :: CodeActionProvider
codeActionProvider pid docId r ctx = do
  support <- clientSupportsDocumentChanges
  codeActionProvider' support pid docId r ctx

codeActionProvider' :: Bool -> CodeActionProvider
codeActionProvider' supportsDocChanges _ docId _ context =
  let LSP.List diags = context ^. LSP.diagnostics
      terms = concatMap getRenamables diags
      renameActions = map (uncurry mkRenamableAction) terms
      redundantTerms = mapMaybe getRedundantImports diags
      redundantActions = concatMap (uncurry mkRedundantImportActions) redundantTerms
      typedHoleActions = concatMap mkTypedHoleActions (mapMaybe getTypedHoles diags)
      missingSignatures = mapMaybe getMissingSignatures diags
      topLevelSignatureActions = map (uncurry mkMissingSignatureAction) missingSignatures
      unusedTerms = mapMaybe getUnusedTerms diags
      unusedTermActions = map (uncurry mkUnusedTermAction) unusedTerms
  in return $ IdeResultOk $ concat [ renameActions
                                   , redundantActions
                                   , typedHoleActions
                                   , topLevelSignatureActions
                                   , unusedTermActions
                                   ]

  where

    docUri = docId ^. LSP.uri

    mkWorkspaceEdit :: [LSP.TextEdit] -> LSP.WorkspaceEdit
    mkWorkspaceEdit es = do
      let changes = HM.singleton docUri (LSP.List es)
          docChanges = LSP.List [textDocEdit]
          textDocEdit = LSP.TextDocumentEdit docId (LSP.List es)
      if supportsDocChanges
        then LSP.WorkspaceEdit Nothing (Just docChanges)
        else LSP.WorkspaceEdit (Just changes) Nothing

    mkRenamableAction :: LSP.Diagnostic -> T.Text -> LSP.CodeAction
    mkRenamableAction diag replacement = codeAction
     where
       title = "Replace with " <> replacement
       kind = LSP.CodeActionQuickFix
       diags = LSP.List [diag]
       we = mkWorkspaceEdit [textEdit]
       textEdit = LSP.TextEdit (diag ^. LSP.range) replacement
       codeAction = LSP.CodeAction title (Just kind) (Just diags) (Just we) Nothing

    getRenamables :: LSP.Diagnostic -> [(LSP.Diagnostic, T.Text)]
    getRenamables diag@(LSP.Diagnostic _ _ _ (Just "bios") msg _) = map (diag,) $ extractRenamableTerms msg
    getRenamables _ = []

    mkRedundantImportActions :: LSP.Diagnostic -> T.Text -> [LSP.CodeAction]
    mkRedundantImportActions diag modName = [removeAction, importAction]
      where
        removeAction = LSP.CodeAction "Remove redundant import"
                                    (Just LSP.CodeActionQuickFix)
                                    (Just (LSP.List [diag]))
                                    (Just removeEdit)
                                    Nothing

        removeEdit = mkWorkspaceEdit [LSP.TextEdit range ""]
        range = LSP.Range (diag ^. LSP.range . LSP.start)
                          (LSP.Position ((diag ^. LSP.range . LSP.start . LSP.line) + 1) 0)

        importAction = LSP.CodeAction "Import instances"
                                    (Just LSP.CodeActionQuickFix)
                                    (Just (LSP.List [diag]))
                                    (Just importEdit)
                                    Nothing
        --TODO: Use hsimport to preserve formatting/whitespace
        importEdit = mkWorkspaceEdit [tEdit]
        tEdit = LSP.TextEdit (diag ^. LSP.range) ("import " <> modName <> "()")

    getRedundantImports :: LSP.Diagnostic -> Maybe (LSP.Diagnostic, T.Text)
    getRedundantImports diag@(LSP.Diagnostic _ _ _ (Just "bios") msg _) = (diag,) <$> extractRedundantImport msg
    getRedundantImports _ = Nothing

    mkTypedHoleActions :: TypedHoles -> [LSP.CodeAction]
    mkTypedHoleActions (TypedHoles diag (TypeDef want) (ValidSubstitutions subs) (Bindings bindings))
      | onlyErrorFuncs = substitutions <> suggestions
      | otherwise = substitutions
      where
        onlyErrorFuncs = null
                       $ map fsName subs \\ ["undefined", "error", "errorWithoutStackTrace"]
        substitutions = map mkHoleAction subs
        suggestions = map mkHoleAction bindings
        mkHoleAction (FunctionSig name (TypeDef sig)) = codeAction
          where title :: T.Text
                title = "Substitute hole (" <> want <> ") with " <> name <> " (" <> sig <> ")"
                diags = LSP.List [diag]
                edit = mkWorkspaceEdit [LSP.TextEdit (diag ^. LSP.range) name]
                kind = LSP.CodeActionQuickFix
                codeAction = LSP.CodeAction title (Just kind) (Just diags) (Just edit) Nothing


    getTypedHoles :: LSP.Diagnostic -> Maybe TypedHoles
    getTypedHoles diag@(LSP.Diagnostic _ _ _ (Just "bios") msg _) =
      case extractHoleSubstitutions msg of
        Nothing -> Nothing
        Just (want, subs, bindings) -> Just $ TypedHoles diag want subs bindings
    getTypedHoles _ = Nothing

    getMissingSignatures :: LSP.Diagnostic -> Maybe (LSP.Diagnostic, T.Text)
    getMissingSignatures diag@(LSP.Diagnostic _ _ _ (Just "bios") msg _) =
      case extractMissingSignature msg of
        Nothing -> Nothing
        Just signature -> Just (diag, signature)
    getMissingSignatures _ = Nothing

    mkMissingSignatureAction :: LSP.Diagnostic -> T.Text -> LSP.CodeAction
    mkMissingSignatureAction diag sig =  codeAction
      where title :: T.Text
            title = "Add signature: " <> sig
            diags = LSP.List [diag]
            startOfLine = LSP.Position (diag ^. LSP.range . LSP.start . LSP.line) 0
            range = LSP.Range startOfLine startOfLine
            edit = mkWorkspaceEdit [LSP.TextEdit range (sig <> "\n")]
            kind = LSP.CodeActionQuickFix
            codeAction = LSP.CodeAction title (Just kind) (Just diags) (Just edit) Nothing

    getUnusedTerms :: LSP.Diagnostic -> Maybe (LSP.Diagnostic, T.Text)
    getUnusedTerms diag@(LSP.Diagnostic _ _ _ (Just "bios") msg _) =
      case extractUnusedTerm msg of
        Nothing -> Nothing
        Just signature -> Just (diag, signature)
    getUnusedTerms _ = Nothing

    mkUnusedTermAction :: LSP.Diagnostic -> T.Text -> LSP.CodeAction
    mkUnusedTermAction diag term = LSP.CodeAction title (Just kind) (Just diags) Nothing (Just cmd)
      where title :: T.Text
            title = "Prefix " <> term <> " with _"
            diags = LSP.List [diag]
            newTerm = "_" <> term
            pos = diag ^. (LSP.range . LSP.start)
            kind = LSP.CodeActionQuickFix
            cmdArgs = LSP.List
              [ Object $ HM.fromList [("file", toJSON docUri),("pos", toJSON pos), ("text", toJSON newTerm)]]
            -- The command label isen't used since the command is never presented to the user
            cmd  = LSP.Command "Unused command label" "hare:rename" (Just cmdArgs)

extractRenamableTerms :: T.Text -> [T.Text]
extractRenamableTerms msg
  -- Account for both "Variable not in scope" and "Not in scope"
  | "ot in scope:" `T.isInfixOf` msg = extractSuggestions msg
  | otherwise = []
  where
    extractSuggestions = map Hie.extractTerm
                       . concatMap singleSuggestions
                       . filter isKnownSymbol
                       . T.lines
    singleSuggestions = T.splitOn "), " -- Each suggestion is comma delimited
    isKnownSymbol t = " (imported from" `T.isInfixOf` t  || " (line " `T.isInfixOf` t

extractRedundantImport :: T.Text -> Maybe T.Text
extractRedundantImport msg =
  if ("The import of " `T.isPrefixOf` firstLine || "The qualified import of " `T.isPrefixOf` firstLine)
      && " is redundant" `T.isSuffixOf` firstLine
    then Just $ Hie.extractTerm firstLine
    else Nothing
  where
    firstLine = case T.lines msg of
      [] -> ""
      (l:_) -> l

extractHoleSubstitutions :: T.Text -> Maybe (TypeDef, ValidSubstitutions, Bindings)
extractHoleSubstitutions diag
  | "Found hole:" `T.isInfixOf` diag =
      let (header, subsBlock) = T.breakOn "Valid substitutions include" diag
          (foundHole, expr) = T.breakOn "In the expression:" header
          expectedType = TypeDef
                       . T.strip
                       . fst
                       . T.breakOn "\n"
                       . keepAfter "::"
                       $ foundHole
          bindingsBlock = T.dropWhile (== '\n')
                        . keepAfter "Relevant bindings include"
                        $ expr
          substitutions = extractSignatures
                        . T.dropWhile (== '\n')
                        . fromMaybe ""
                        . T.stripPrefix "Valid substitutions include"
                        $ subsBlock
          bindings = extractSignatures bindingsBlock
      in Just (expectedType, ValidSubstitutions substitutions, Bindings bindings)
  | otherwise = Nothing
  where
    keepAfter prefix = fromMaybe ""
                     . T.stripPrefix prefix
                     . snd
                     . T.breakOn prefix

    extractSignatures :: T.Text -> [FunctionSig]
    extractSignatures tBlock = map nameAndSig
                              . catMaybes
                              . gatherLastGroup
                              . mapAccumL (groupSignatures (countSpaces tBlock)) T.empty
                              . T.lines
                              $ tBlock

    countSpaces = T.length . T.takeWhile (== ' ')

    groupSignatures indentSize acc line
      | "(" `T.isPrefixOf` T.strip line = (acc, Nothing)
      | countSpaces line == indentSize && acc /= T.empty = (T.strip line, Just acc)
      | otherwise = (acc <> " " <> T.strip line, Nothing)

    gatherLastGroup :: (T.Text, [Maybe T.Text]) -> [Maybe T.Text]
    gatherLastGroup ("", groupped) = groupped
    gatherLastGroup (lastGroup, groupped) = groupped ++ [Just lastGroup]

    nameAndSig :: T.Text -> FunctionSig
    nameAndSig t = FunctionSig extractName extractSig
      where
        extractName = T.strip . fst . T.breakOn "::" $ t
        extractSig = TypeDef
                   . T.strip
                   . fst
                   . T.breakOn "(bound at"
                   . keepAfter "::"
                   $ t

extractMissingSignature :: T.Text -> Maybe T.Text
extractMissingSignature msg = extractSignature <$> stripMessageStart msg
  where
    stripMessageStart = T.stripPrefix "Top-level binding with no type signature:"
                      . T.strip
    extractSignature = T.strip

extractUnusedTerm :: T.Text -> Maybe T.Text
extractUnusedTerm msg = Hie.extractTerm <$> stripMessageStart msg
  where
    stripMessageStart = T.stripPrefix "Defined but not used:"
                      . T.strip

-- ---------------------------------------------------------------------

hoverProvider :: HoverProvider
hoverProvider doc pos = runIdeResultT $ do
  info' <- IdeResultT $ newTypeCmd pos doc
  names' <- IdeResultT $ pluginGetFile "ghc-mod:hoverProvider" doc $ \fp ->
    ifCachedModule fp (IdeResultOk []) $ \(_ :: GHC.ParsedModule) info ->
      return $ IdeResultOk $ Hie.getSymbolsAtPoint pos info
  let
    f = (==) `on` (Hie.showName . snd)
    f' = compare `on` (Hie.showName . snd)
    names = mapMaybe pickName $ groupBy f $ sortBy f' names'
    pickName [] = Nothing
    pickName [x] = Just x
    pickName xs@(x:_) = case find (isJust . nameModule_maybe . snd) xs of
      Nothing -> Just x
      Just a -> Just a
    nnames = length names
    (info,mrange) =
      case map last $ groupBy ((==) `on` fst) info' of
        ((r,typ):_) ->
          case find ((r ==) . fst) names of
            Nothing ->
              (Just $ LSP.markedUpContent "haskell" $ "_ :: " <> typ, Just r)
            Just (_,name)
              | nnames == 1 ->
                (Just $ LSP.markedUpContent "haskell" $ Hie.showName name <> " :: " <> typ, Just r)
              | otherwise ->
                (Just $ LSP.markedUpContent "haskell" $ "_ :: " <> typ, Just r)
        [] -> case names of
          [] -> (Nothing, Nothing)
          ((r,_):_) -> (Nothing, Just r)
  return $ case mrange of
    Just r -> [LSP.Hover (LSP.HoverContents $ mconcat $ catMaybes [info]) (Just r)]
    Nothing -> []

-- ---------------------------------------------------------------------

data Decl = Decl LSP.SymbolKind (Located RdrName) [Decl] SrcSpan
          | Import LSP.SymbolKind (Located ModuleName) [Decl] SrcSpan

symbolProvider :: Uri -> IdeDeferM (IdeResult [LSP.DocumentSymbol])
symbolProvider uri = pluginGetFile "ghc-mod symbolProvider: " uri $
  \file -> withCachedModule file (IdeResultOk []) $ \pm _ -> do
    let hsMod = unLoc $ pm_parsed_source pm
        imports = hsmodImports hsMod
        imps  = concatMap goImport imports
        decls = concatMap go $ hsmodDecls hsMod

        go :: LHsDecl C.GhcPs -> [Decl]
#if __GLASGOW_HASKELL__ >= 806
        go (L l (TyClD _ d)) = goTyClD (L l d)
#else
        go (L l (TyClD   d)) = goTyClD (L l d)
#endif

#if __GLASGOW_HASKELL__ >= 806
        go (L l (ValD _ d)) = goValD (L l d)
#else
        go (L l (ValD   d)) = goValD (L l d)
#endif
#if __GLASGOW_HASKELL__ >= 806
        go (L l (ForD _ ForeignImport { fd_name = n })) = pure (Decl LSP.SkFunction n [] l)
#else
        go (L l (ForD   ForeignImport { fd_name = n })) = pure (Decl LSP.SkFunction n [] l)
#endif
        go _ = []

        -- -----------------------------

        goTyClD (L l (FamDecl { tcdFam = FamilyDecl { fdLName = n } })) = pure (Decl LSP.SkClass n [] l)
        goTyClD (L l (SynDecl { tcdLName = n })) = pure (Decl LSP.SkClass n [] l)
        goTyClD (L l (DataDecl { tcdLName = n, tcdDataDefn = HsDataDefn { dd_cons = cons } })) =
          pure (Decl LSP.SkClass n (concatMap processCon cons) l)
        goTyClD (L l (ClassDecl { tcdLName = n, tcdSigs = sigs, tcdATs = fams })) =
          pure (Decl LSP.SkInterface n children l)
          where children = famDecls ++ sigDecls
#if __GLASGOW_HASKELL__ >= 806
                famDecls = concatMap (go . fmap (TyClD NoExt . FamDecl NoExt)) fams
#else
                famDecls = concatMap (go . fmap (TyClD . FamDecl)) fams
#endif
                sigDecls = concatMap processSig sigs
#if __GLASGOW_HASKELL__ >= 806
        goTyClD (L _ (FamDecl _ (XFamilyDecl _)))        = error "goTyClD"
        goTyClD (L _ (DataDecl _ _ _ _ (XHsDataDefn _))) = error "goTyClD"
        goTyClD (L _ (XTyClDecl _))                      = error "goTyClD"
#endif

        -- -----------------------------

        goValD :: LHsBind C.GhcPs -> [Decl]
        goValD (L l (FunBind { fun_id = ln, fun_matches = MG { mg_alts = llms } })) =
          pure (Decl LSP.SkFunction ln wheres l)
          where
            wheres = concatMap (gomatch . unLoc) (unLoc llms)
            gomatch Match { m_grhss = GRHSs { grhssLocalBinds = lbs } } = golbs (unLoc lbs)
#if __GLASGOW_HASKELL__ >= 806
            gomatch (Match _ _ _ (XGRHSs _)) = error "gomatch"
            gomatch (XMatch _)               = error "gomatch"

            golbs (HsValBinds _ (ValBinds _ lhsbs _)) = concatMap (go . fmap (ValD NoExt)) lhsbs
#else
            golbs (HsValBinds (ValBindsIn lhsbs _ )) = concatMap (go . fmap ValD) lhsbs
#endif
            golbs _ = []

        goValD (L l (PatBind { pat_lhs = p })) =
          map (\n -> Decl LSP.SkVariable n [] l) $ hsNamessRdr p

#if __GLASGOW_HASKELL__ >= 806
        goValD (L l (PatSynBind _ idR)) = case idR of
          XPatSynBind _ -> error "xPatSynBind"
          PSB { psb_id = ln } ->
#else
        goValD (L l (PatSynBind (PSB { psb_id = ln }))) =
#endif
            -- We are reporting pattern synonyms as functions. There is no such
            -- thing as pattern synonym in current LSP specification so we pick up
            -- an (arguably) closest match.
            pure (Decl LSP.SkFunction ln [] l)

#if __GLASGOW_HASKELL__ >= 806
        goValD (L _ (FunBind _ _ (XMatchGroup _) _ _)) = error "goValD"
        goValD (L _ (VarBind _ _ _ _))                 = error "goValD"
        goValD (L _ (AbsBinds _ _ _ _ _ _ _))          = error "goValD"
        goValD (L _ (XHsBindsLR _))                    = error "goValD"
#elif __GLASGOW_HASKELL__ >= 804
        goValD (L _ (VarBind _ _ _))        = error "goValD"
        goValD (L _ (AbsBinds _ _ _ _ _ _)) = error "goValD"
#else
        goValD (L _ (VarBind _ _ _))           = error "goValD"
        goValD (L _ (AbsBinds _ _ _ _ _))      = error "goValD"
        goValD (L _ (AbsBindsSig _ _ _ _ _ _)) = error "goValD"
#endif

        -- -----------------------------

        processSig :: LSig C.GhcPs -> [Decl]
#if __GLASGOW_HASKELL__ >= 806
        processSig (L l (ClassOpSig _ False names _)) =
#else
        processSig (L l (ClassOpSig False names _)) =
#endif
          map (\n -> Decl LSP.SkMethod n [] l) names
        processSig _ = []

        processCon :: LConDecl C.GhcPs -> [Decl]
        processCon (L l ConDeclGADT { con_names = names }) =
          map (\n -> Decl LSP.SkConstructor n [] l) names
#if __GLASGOW_HASKELL__ >= 806
        processCon (L l ConDeclH98 { con_name = name, con_args    = dets }) =
#else
        processCon (L l ConDeclH98 { con_name = name, con_details = dets }) =
#endif
          pure (Decl LSP.SkConstructor name xs l)
          where
            f (L fl ln) = Decl LSP.SkField ln [] fl
            xs = case dets of
              RecCon (L _ rs) -> concatMap (map (f . fmap rdrNameFieldOcc)
                                            . cd_fld_names
                                            . unLoc) rs
              _ -> []
#if __GLASGOW_HASKELL__ >= 806
        processCon (L _ (XConDecl _)) = error "processCon"
#endif

        goImport :: LImportDecl C.GhcPs -> [Decl]
        goImport (L l ImportDecl { ideclName = lmn, ideclAs = as, ideclHiding = meis }) = pure im
          where
            im = Import imKind lmn xs l
            imKind
              | isJust as = LSP.SkNamespace
              | otherwise = LSP.SkModule
            xs = case meis of
                    Just (False, eis) -> concatMap f (unLoc eis)
                    _ -> []
#if __GLASGOW_HASKELL__ >= 806
            f (L l' (IEVar _ n))      = pure (Decl LSP.SkFunction (ieLWrappedName n) [] l')
            f (L l' (IEThingAbs _ n)) = pure (Decl LSP.SkClass (ieLWrappedName n) [] l')
            f (L l' (IEThingAll _ n)) = pure (Decl LSP.SkClass (ieLWrappedName n) [] l')
            f (L l' (IEThingWith _ n _ vars fields)) =
#else
            f (L l' (IEVar n))      = pure (Decl LSP.SkFunction (ieLWrappedName n) [] l')
            f (L l' (IEThingAbs n)) = pure (Decl LSP.SkClass (ieLWrappedName n) [] l')
            f (L l' (IEThingAll n)) = pure (Decl LSP.SkClass (ieLWrappedName n) [] l')
            f (L l' (IEThingWith n _ vars fields)) =
#endif
              let funcDecls  = map (\n' -> Decl LSP.SkFunction (ieLWrappedName n') [] (getLoc n')) vars
                  fieldDecls = map (\f' -> Decl LSP.SkField (flSelector <$> f') [] (getLoc f')) fields
                  children = funcDecls ++ fieldDecls
                in pure (Decl LSP.SkClass (ieLWrappedName n) children l')
            f _ = []
#if __GLASGOW_HASKELL__ >= 806
        goImport (L _ (XImportDecl _)) = error "goImport"
#endif

        declsToSymbolInf :: Decl -> IdeDeferM [LSP.DocumentSymbol]
        declsToSymbolInf (Decl kind (L nl rdrName) children l) =
          declToSymbolInf' l kind nl (Hie.showName rdrName) children
        declsToSymbolInf (Import kind (L nl modName) children l) =
          declToSymbolInf' l kind nl (Hie.showName modName) children

        declToSymbolInf' :: SrcSpan -> LSP.SymbolKind -> SrcSpan -> T.Text -> [Decl] -> IdeDeferM [LSP.DocumentSymbol]
        declToSymbolInf' ss kind nss name children = do
          childrenSymbols <- concat <$> mapM declsToSymbolInf children
          case (srcSpan2Range ss, srcSpan2Range nss) of
            (Right r, Right selR) ->
              let chList = Just (LSP.List childrenSymbols)
              in return $ pure $
                LSP.DocumentSymbol name (Just "") kind Nothing r selR chList
            _ -> return childrenSymbols

    symInfs <- concat <$> mapM declsToSymbolInf (imps ++ decls)
    return $ IdeResultOk symInfs
