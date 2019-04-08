{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}

module Haskell.Ide.Engine.ModuleCache
  ( modifyCache
  , withCradle
  , ifCachedInfo
  , withCachedInfo
  , ifCachedModule
  , ifCachedModuleM
  , ifCachedModuleAndData
  , withCachedModule
  , withCachedModuleAndData
  , deleteCachedModule
  , failModule
  , cacheModule
  , cacheModules
  , cacheInfoNoClear
  , runActionWithContext
  , ModuleCache(..)
  ) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Free
import           Data.Dynamic (toDyn, fromDynamic, Dynamic)
import           Data.Generics (Proxy(..), TypeRep, typeRep, typeOf)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Typeable (Typeable)
import           Exception (ExceptionMonad)
import           System.Directory
import           System.FilePath

import Debug.Trace

import qualified GhcMod.Cradle as GM
import qualified GhcMod.Monad  as GM
import qualified GhcMod.Types  as GM
import qualified GhcMod.Utils  as GM
import qualified GHC           as GHC
import qualified DynFlags      as GHC
import qualified HscMain       as GHC
import qualified HscTypes      as GHC
import qualified Data.Trie.Convenience as T
import qualified Data.Trie as T
import qualified HIE.Bios as BIOS
import qualified Data.ByteString.Char8 as B

import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.GhcModuleCache
import           Haskell.Ide.Engine.MultiThreadState
import           Haskell.Ide.Engine.PluginsIdeMonads

-- ---------------------------------------------------------------------

modifyCache :: (HasGhcModuleCache m) => (GhcModuleCache -> GhcModuleCache) -> m ()
modifyCache f = do
  mc <- getModuleCache
  setModuleCache (f mc)

-- ---------------------------------------------------------------------
-- | Runs an IdeM action with the given Cradle
withCradle :: GHC.GhcMonad m => FilePath -> BIOS.Cradle -> m a -> m a
withCradle fp crdl body = do
  body

  --GM.gmeLocal (\env -> env {GM.gmCradle = crdl})


-- ---------------------------------------------------------------------
-- | Runs an action in a ghc-mod Cradle found from the
-- directory of the given file. If no file is found
-- then runs the action in the default cradle.
-- Sets the current directory to the cradle root dir
-- in either case
runActionWithContext :: (GHC.GhcMonad m, HasGhcModuleCache m)
                     => GHC.DynFlags -> Maybe FilePath -> m a -> m a
runActionWithContext df Nothing action = do
  -- Cradle with no additional flags
  dir <- liftIO $ getCurrentDirectory
  --This causes problems when loading a later package which sets the
  --packageDb
  --withCradle (BIOS.defaultCradle dir) action
  action
runActionWithContext df (Just uri) action = do
  getCradle uri (\lc -> loadCradle df lc >> action)

loadCradle :: (HasGhcModuleCache m, GHC.GhcMonad m) => GHC.DynFlags -> LookupCradleResult -> m ()
loadCradle _ ReuseCradle = do
    traceM ("Reusing cradle")
loadCradle iniDynFlags (NewCradle fp) = do
    traceShowM ("New cradle" , fp)
    -- Cache the existing cradle
    maybe (return ()) cacheCradle =<< (currentCradle <$> getModuleCache)

    -- Now load the new cradle
    crdl <- liftIO $ BIOS.findCradle fp
    traceShowM crdl
    liftIO (GHC.newHscEnv iniDynFlags) >>= GHC.setSession
    liftIO $ setCurrentDirectory (BIOS.cradleRootDir crdl)
    BIOS.initializeFlagsWithCradle fp crdl
    GHC.getSessionDynFlags >>= setCurrentCradle crdl
loadCradle iniDynFlags (LoadCradle (CachedCradle crd env)) = do
    traceShowM ("Reload Cradle" , crd)
    -- Cache the existing cradle
    maybe (return ()) cacheCradle =<< (currentCradle <$> getModuleCache)
    GHC.setSession env
    setCurrentCradle crd (GHC.hsc_dflags env)



setCurrentCradle :: (HasGhcModuleCache m, GHC.GhcMonad m) => BIOS.Cradle -> GHC.DynFlags -> m ()
setCurrentCradle crdl df = do
    let dirs = GHC.importPaths df
    traceShowM dirs
    dirs' <- liftIO $ mapM canonicalizePath dirs
    modifyCache (\s -> s { currentCradle = Just (dirs', crdl) })


cacheCradle :: (HasGhcModuleCache m, GHC.GhcMonad m) => ([FilePath], BIOS.Cradle) -> m ()
cacheCradle (ds, c) = do
  env <- GHC.getSession
  let cc = CachedCradle c env
      new_map = T.fromList (map (, cc) (map B.pack ds))
  modifyCache (\s -> s { cradleCache = T.unionWith (\a _ -> a) new_map (cradleCache s) })

-- | Get the Cradle that should be used for a given URI
--getCradle :: (GM.GmEnv m, GM.MonadIO m, HasGhcModuleCache m, GM.GmLog m
--             , MonadBaseControl IO m, ExceptionMonad m, GM.GmOut m)
getCradle :: (GHC.GhcMonad m, HasGhcModuleCache m)
         => FilePath -> (LookupCradleResult -> m r) -> m r
getCradle fp k = do
      canon_fp <- liftIO $ canonicalizePath fp
      mcache <- getModuleCache
      k (lookupCradle canon_fp mcache)

ifCachedInfo :: (HasGhcModuleCache m, MonadIO m) => FilePath -> a -> (CachedInfo -> m a) -> m a
ifCachedInfo fp def callback = do
  muc <- getUriCache fp
  case muc of
    Just (UriCacheSuccess uc) -> callback (cachedInfo uc)
    _ -> return def

withCachedInfo :: FilePath -> a -> (CachedInfo -> IdeDeferM a) -> IdeDeferM a
withCachedInfo fp def callback = deferIfNotCached fp go
  where go (UriCacheSuccess uc) = callback (cachedInfo uc)
        go UriCacheFailed = return def

ifCachedModule :: (HasGhcModuleCache m, GM.MonadIO m, CacheableModule b) => FilePath -> a -> (b -> CachedInfo -> m a) -> m a
ifCachedModule fp def callback = ifCachedModuleM fp (return def) callback

-- | Calls the callback with the cached module for the provided path.
-- Otherwise returns the default immediately if there is no cached module
-- available.
-- If you need custom data, see also 'ifCachedModuleAndData'.
-- If you are in IdeDeferM and would like to wait until a cached module is available,
-- see also 'withCachedModule'.
ifCachedModuleM :: (HasGhcModuleCache m, GM.MonadIO m, CacheableModule b)
                => FilePath -> m a -> (b -> CachedInfo -> m a) -> m a
ifCachedModuleM fp k callback = do
  muc <- getUriCache fp
  let x = do
        res <- muc
        case res of
          UriCacheSuccess uc -> do
            let ci = cachedInfo uc
            cm <- fromUriCache uc
            return (ci, cm)
          UriCacheFailed -> Nothing
  case x of
    Just (ci, cm) -> callback cm ci
    Nothing -> k

-- | Calls the callback with the cached module and data for the provided path.
-- Otherwise returns the default immediately if there is no cached module
-- available.
-- If you are in IdeDeferM and would like to wait until a cached module is available,
-- see also 'withCachedModuleAndData'.
ifCachedModuleAndData :: forall a b m. (ModuleCache a, HasGhcModuleCache m, GM.MonadIO m, MonadMTState IdeState m)
                      => FilePath -> b -> (GHC.TypecheckedModule -> CachedInfo -> a -> m b) -> m b
ifCachedModuleAndData fp def callback = do
  muc <- getUriCache fp
  case muc of
    Just (UriCacheSuccess uc@(UriCache info _ (Just tm) dat _)) ->
      case fromUriCache uc of
        Just modul -> lookupCachedData fp tm info dat >>= callback modul (cachedInfo uc)
        Nothing -> return def
    _ -> return def

-- | Calls the callback with the cached module for the provided path.
-- If there is no cached module immediately available, it will call the callback once
-- the module has been cached.
-- If that module fails to load, it will then return then default as a last resort.
-- If you need custom data, see also 'withCachedModuleAndData'.
-- If you don't want to wait until a cached module is available,
-- see also 'ifCachedModule'.
withCachedModule :: CacheableModule b => FilePath -> a -> (b -> CachedInfo -> IdeDeferM a) -> IdeDeferM a
withCachedModule fp def callback = deferIfNotCached fp go
  where go (UriCacheSuccess uc@(UriCache _ _ _ _ _)) =
          case fromUriCache uc of
            Just modul -> callback modul (cachedInfo uc)
            Nothing -> wrap (Defer fp go)
        go UriCacheFailed = return def

-- | Calls its argument with the CachedModule for a given URI
-- along with any data that might be stored in the ModuleCache.
-- If the module is not already cached, then the callback will be
-- called as soon as it is available.
-- The data is associated with the CachedModule and its cache is
-- invalidated when a new CachedModule is loaded.
-- If the data doesn't exist in the cache, new data is generated
-- using by calling the `cacheDataProducer` function.
withCachedModuleAndData :: forall a b. (ModuleCache a)
                        => FilePath -> b
                        -> (GHC.TypecheckedModule -> CachedInfo -> a -> IdeDeferM b) -> IdeDeferM b
withCachedModuleAndData fp def callback = deferIfNotCached fp go
  where go (UriCacheSuccess (uc@(UriCache info _ (Just tm) dat _))) =
          lookupCachedData fp tm info dat >>= callback tm (cachedInfo uc)
        go (UriCacheSuccess (UriCache { cachedTcMod = Nothing })) = wrap (Defer fp go)
        go UriCacheFailed = return def

getUriCache :: (HasGhcModuleCache m, MonadIO m) => FilePath -> m (Maybe UriCacheResult)
getUriCache fp = do
  canonical_fp <- liftIO $ canonicalizePath fp
  raw_res <- fmap (Map.lookup canonical_fp . uriCaches) getModuleCache
  case raw_res of
    Just uri_res -> liftIO $ checkModuleHash canonical_fp uri_res
    Nothing      -> return Nothing

checkModuleHash :: FilePath -> UriCacheResult -> IO (Maybe UriCacheResult)
checkModuleHash fp r@(UriCacheSuccess uri_res) = do
  cur_hash <- hashModule fp
  return $ if cachedHash uri_res == cur_hash
    then Just r
    else Nothing
checkModuleHash _ r = return (Just r)

deferIfNotCached :: FilePath -> (UriCacheResult -> IdeDeferM a) -> IdeDeferM a
deferIfNotCached fp cb = do
  muc <- getUriCache fp
  case muc of
    Just res -> cb res
    Nothing -> wrap (Defer fp cb)

lookupCachedData :: forall a m. (HasGhcModuleCache m, MonadMTState IdeState m, GM.MonadIO m, Typeable a, ModuleCache a)
                 => FilePath -> GHC.TypecheckedModule -> CachedInfo -> (Map.Map TypeRep Dynamic) -> m a
lookupCachedData fp tm info dat = do
  canonical_fp <- liftIO $ canonicalizePath fp
  let proxy :: Proxy a
      proxy = Proxy
  case Map.lookup (typeRep proxy) dat of
    Nothing -> do
      val <- cacheDataProducer tm info
      h <- liftIO $ hashModule canonical_fp
      let dat' = Map.insert (typeOf val) (toDyn val) dat
          newUc = UriCache info (GHC.tm_parsed_module tm) (Just tm) dat' h
      modifyCache (\s -> s {uriCaches = Map.insert canonical_fp (UriCacheSuccess newUc)
                                                  (uriCaches s)})
      return val

    Just x ->
      case fromDynamic x of
        Just val -> return val
        Nothing  -> error "impossible"

cacheModules :: (FilePath -> FilePath) -> [GHC.TypecheckedModule] -> IdeGhcM ()
cacheModules rfm ms = mapM_ go_one ms
  where
    go_one m = case get_fp m of
                 Just fp -> cacheModule (rfm fp) (Right m)
                 Nothing -> return ()
    get_fp = GHC.ml_hs_file . GHC.ms_location . GHC.pm_mod_summary . GHC.tm_parsed_module

-- | Saves a module to the cache and executes any deferred
-- responses waiting on that module.
cacheModule :: FilePath -> (Either GHC.ParsedModule GHC.TypecheckedModule) -> IdeGhcM ()
cacheModule fp modul = do
  canonical_fp <- liftIO $ canonicalizePath fp
  rfm <- reverseFileMap
  fp_hash <- liftIO $ hashModule fp
  newUc <-
    case modul of
      Left pm -> do
        muc <- getUriCache canonical_fp
        let defInfo = CachedInfo mempty mempty mempty mempty rfm return return
        return $ case muc of
          Just (UriCacheSuccess uc) ->
            let newCI = (cachedInfo uc) { revMap = rfm }
              in uc { cachedPsMod = pm, cachedInfo = newCI, cachedHash = fp_hash }
          _ -> UriCache defInfo pm Nothing mempty fp_hash

      Right tm -> do
        typm <- genTypeMap tm
        let info = CachedInfo (genLocMap tm) typm (genImportMap tm) (genDefMap tm) rfm return return
            pm = GHC.tm_parsed_module tm
        return $ UriCache info pm (Just tm) mempty fp_hash

  let res = UriCacheSuccess newUc
  modifyCache $ \gmc ->
      gmc { uriCaches = Map.insert canonical_fp res (uriCaches gmc) }

  -- execute any queued actions for the module
  runDeferredActions canonical_fp res

-- | Marks a module that it failed to load and triggers
-- any deferred responses waiting on it
failModule :: FilePath -> IdeGhcM ()
failModule fp = do
  fp' <- liftIO $ canonicalizePath fp

  maybeUriCache <- fmap (Map.lookup fp' . uriCaches) getModuleCache

  let res = UriCacheFailed

  case maybeUriCache of
    Just _ -> return ()
    Nothing ->
      -- If there's no cache for the module mark it as failed
      modifyCache (\gmc ->
          gmc {
            uriCaches = Map.insert fp' res (uriCaches gmc)
          }
        )

      -- Fail the queued actions
  runDeferredActions fp' res


runDeferredActions :: FilePath -> UriCacheResult -> IdeGhcM ()
runDeferredActions uri res = do
      actions <- fmap (fromMaybe [] . Map.lookup uri) (requestQueue <$> readMTS)
      -- remove queued actions
      modifyMTS $ \s -> s { requestQueue = Map.delete uri (requestQueue s) }

      liftToGhc $ forM_ actions (\a -> a res)


-- | Saves a module to the cache without clearing the associated cache data - use only if you are
-- sure that the cached data associated with the module doesn't change
cacheInfoNoClear :: (MonadIO m, HasGhcModuleCache m)
                 => FilePath -> CachedInfo -> m ()
cacheInfoNoClear uri ci = do
  uri' <- liftIO $ canonicalizePath uri
  modifyCache (\gmc ->
      gmc { uriCaches = Map.adjust
                          updateCachedInfo
                          uri'
                          (uriCaches gmc)
          }
    )
  where
    updateCachedInfo :: UriCacheResult -> UriCacheResult
    updateCachedInfo (UriCacheSuccess old) = UriCacheSuccess (old { cachedInfo = ci })
    updateCachedInfo UriCacheFailed        = UriCacheFailed

-- | Deletes a module from the cache
deleteCachedModule :: (MonadIO m, HasGhcModuleCache m) => FilePath -> m ()
deleteCachedModule uri = do
  uri' <- liftIO $ canonicalizePath uri
  modifyCache (\s -> s { uriCaches = Map.delete uri' (uriCaches s) })

-- ---------------------------------------------------------------------
-- | A ModuleCache is valid for the lifetime of a CachedModule
-- It is generated on need and the cache is invalidated
-- when a new CachedModule is loaded.
-- Allows the caching of arbitary data linked to a particular
-- TypecheckedModule.
-- TODO: this name is confusing, given GhcModuleCache. Change it
class Typeable a => ModuleCache a where
    -- | Defines an initial value for the state extension
    cacheDataProducer :: (GM.MonadIO m, MonadMTState IdeState m)
                      => GHC.TypecheckedModule -> CachedInfo -> m a

instance ModuleCache () where
    cacheDataProducer = const $ const $ return ()
