{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}

module Haskell.Ide.Engine.Cradle  where

import           HIE.Bios as BIOS
import           HIE.Bios.Types as BIOS
import           Haskell.Ide.Engine.MonadFunctions
import           Distribution.Helper (Package, projectPackages, pUnits,
                                      pSourceDir, ChComponentInfo(..),
                                      unChModuleName, Ex(..), ProjLoc(..),
                                      QueryEnv, mkQueryEnv, runQuery,
                                      Unit, unitInfo, uiComponents,
                                      ChEntrypoint(..))
import           Distribution.Helper.Discover (findProjects, getDefaultDistDir)
import           Data.Function ((&))
import           Data.List (isPrefixOf)
import qualified Data.List.NonEmpty as NonEmpty
import           Data.List.NonEmpty (NonEmpty)
import qualified Data.Map as M
import           Data.List (sortOn, find)
import           Data.Maybe (listToMaybe, mapMaybe, isJust)
import           Data.Ord (Down(..))
import           Data.Foldable (toList)
import           Control.Exception (IOException, try)
import           System.FilePath
import           System.Directory (getCurrentDirectory, canonicalizePath, findExecutable)
import           System.Exit

-- | Find the cradle that the given File belongs to.
--
-- First looks for a "hie.yaml" file in the directory of the file
-- or one of its parents. If this file is found, the cradle
-- is read from the config. If this config does not comply to the "hie.yaml"
-- specification, an error is raised.
--
-- If no "hie.yaml" can be found, the implicit config is used.
-- The implicit config uses different heuristics to determine the type
-- of the project that may or may not be accurate.
findLocalCradle :: FilePath -> IO Cradle
findLocalCradle fp = do
  cradleConf <- BIOS.findCradle fp
  case cradleConf of
    Just yaml -> fixCradle <$> BIOS.loadCradle yaml
    Nothing   -> cabalHelperCradle fp

-- | Check if the given cradle is a stack cradle.
-- This might be used to determine the GHC version to use on the project.
-- If it is a stack-cradle, we have to use `stack path --compiler-exe`
-- otherwise we may ask `ghc` directly what version it is.
isStackCradle :: Cradle -> Bool
isStackCradle = (`elem` ["stack", "Cabal-Helper-Stack", "Cabal-Helper-Stack-None"])
  . BIOS.actionName
  . BIOS.cradleOptsProg

{- | Finds a Cabal v2-project, Cabal v1-project or a Stack project
relative to the given FilePath.
Cabal v2-project and Stack have priority over Cabal v1-project.
This entails that if a Cabal v1-project can be identified, it is
first checked whether there are Stack projects or Cabal v2-projects
before it is concluded that this is the project root.
Cabal v2-projects and Stack projects are equally important.
Due to the lack of user-input we have to guess which project it
should rather be.
This guessing has no guarantees and may change at any time.

=== Example:

Assume the following project structure:
  /
  └── Foo/
      ├── Foo.cabal
      ├── stack.yaml
      ├── cabal.project
      ├── src
      │   └── Lib.hs
      └── B/
          ├── B.cabal
          └── src/
              └── Lib2.hs

Assume the call @findCabalHelperEntryPoint "/Foo/B/src/Lib2.hs"@.
We now want to know to which project "/Foo/B/src/Lib2.hs" belongs to
and what the projects root is. If we only do a naive search to find the
first occurrence of either "B.cabal", "stack.yaml", "cabal.project"
or "Foo.cabal", we might assume that the location  of "B.cabal" marks
the project's root directory of which "/Foo/B/src/Lib2.hs" is part of.
However, there is also a "cabal.project" and "stack.yaml" in the parent
directory, which add the package "B" as a package.
So, the compilation of the package "B", and the file "src/Lib2.hs" in it,
does not only depend on the definitions in "B.cabal", but also
on "stack.yaml" and "cabal.project".
The project root is therefore "/Foo/".
Only if there is no "stack.yaml" or "cabal.project" in any of the ancestor
directories, it is safe to assume that "B.cabal" marks the root of the project.

Thus:
>>> findCabalHelperEntryPoint "/Foo/B/src/Lib2.hs
Just (Ex (ProjLocStackYaml { plStackYaml = "/Foo/"}))

or
>>> findCabalHelperEntryPoint "/Foo/B/src/Lib2.hs
Just (Ex (ProjLocV2File { plProjectDirV2 = "/Foo/"}))

In the given example, it is not guaranteed which project type is found,
it is only guaranteed that it will not identify the project
as a cabal v1-project.

Note that this will not return any project types for which the corresponding
build tool is not on the PATH. This is "stack" and "cabal" for stack and cabal
(both v1 and v2) projects respectively.
-}
findCabalHelperEntryPoint :: FilePath -> IO (Maybe (Ex ProjLoc))
findCabalHelperEntryPoint fp = do
  allProjs <- concat <$> mapM findProjects (ancestors (takeDirectory fp))

  debugm $ "Cabal-Helper found these projects: " ++ show (map (\(Ex x) -> show x) allProjs)

  -- We only want to return projects that we have the build tools installed for
  isStackInstalled <- isJust <$> findExecutable "stack"
  isCabalInstalled <- isJust <$> findExecutable "cabal"
  let supportedProjs = filter (\x -> supported x isStackInstalled isCabalInstalled) allProjs
  debugm $ "These projects have the build tools installed: " ++ show (map (\(Ex x) -> show x) supportedProjs)

  case filter (\p -> isCabalNewProject p || isStackProject p) supportedProjs of
    (x:_) -> return $ Just x
    []    -> case filter isCabalOldProject supportedProjs of
      (x:_) -> return $ Just x
      []    -> return Nothing
    where
      supported :: (Ex ProjLoc) -> Bool -> Bool -> Bool
      supported (Ex ProjLocStackYaml {}) stackInstalled _ = stackInstalled
      supported (Ex ProjLocV2Dir {}) _ cabalInstalled = cabalInstalled
      supported (Ex ProjLocV2File {}) _ cabalInstalled = cabalInstalled
      supported (Ex ProjLocV1Dir {}) _ cabalInstalled = cabalInstalled
      supported (Ex ProjLocV1CabalFile {}) _ cabalInstalled = cabalInstalled

      isStackProject (Ex ProjLocStackYaml {}) = True
      isStackProject _ = False

      isCabalNewProject (Ex ProjLocV2Dir {}) = True
      isCabalNewProject (Ex ProjLocV2File {}) = True
      isCabalNewProject _ = False

      isCabalOldProject (Ex ProjLocV1Dir {}) = True
      isCabalOldProject (Ex ProjLocV1CabalFile {}) = True
      isCabalOldProject _ = False

{- | Given a FilePath, find the cradle the FilePath belongs to.

Finds the Cabal Package the FilePath is most likely a part of
and creates a cradle whose root directory is the directory
of the package the File belongs to.

It is not required that the FilePath given actually exists. If it does not
exist or is not part of any of the packages in the project, a "None"-cradle is
produced.
See <https://github.com/mpickering/hie-bios> for what a "None"-cradle is.
The "None"-cradle can still be used to query for basic information, such as
the GHC version used to build the project. However, it can not be used to
load any of the files in the project.

== General Approach

Given a FilePath that we want to load, we need to create a cradle
that can compile and load the given FilePath.
In Cabal-Helper, there is no notion of a cradle, but a project
consists of multiple packages that contain multiple units.
Each unit may consist of multiple components.
A unit is the smallest part of code that Cabal (the library) can compile.
Examples are executables, libraries, tests or benchmarks are all units.
Each of this units has a name that is unique within a build-plan,
such as "exe:hie" which represents the executable of the Haskell IDE Engine.

In principle, a unit is what hie-bios considers to be a cradle.
However, to find out to which unit a FilePath belongs, we have to initialise
the unit, e.g. configure its dependencies and so on. When discovering a cradle
we do not want to pay for this upfront, but rather when we actually want to
load a Module in the project. Therefore, we only identify the package the
FilePath is part of and decide which unit to load when 'runCradle' is executed.

Thus, to find the options required to compile and load the given FilePath,
we have to do the following:

  1. Identify the package that contains the FilePath (should be unique)
     Happens in 'cabalHelperCradle'
  2. Find the unit that that contains the FilePath (May be non-unique)
     Happens in 'cabalHelperAction'
  3. Find the component that exposes the FilePath (May be non-unique)
     Happens in 'cabalHelperAction'

=== Identify the package that contains the FilePath

The function 'cabalHelperCradle' does the first step only.
It starts by querying Cabal-Helper to find the project's root.
See 'findCabalHelperEntryPoint' for details how this is done.
Once the root of the project is defined, we query Cabal-Helper for all packages
that are defined in the project and match by the packages source directory
which package the given FilePath is most likely to be a part of.
E.g. if the source directory of the package is the most concrete
prefix of the FilePath, the FilePath is in that package.
After the package is identified, we create a cradle where cradle's root
directory is set to the package's source directory. This is necessary,
because compiler options obtained from a component, are relative
to the source directory of the package the component is part of.

=== Find the unit that that contains the FilePath

In 'cabalHelperAction' we want to load a given FilePath, already knowing
which package the FilePath is part of. Now we obtain all Units that are part
of the package and match by the source directories (plural is intentional),
to which unit the given FilePath most likely belongs to. If no unit can be
obtained, e.g. for every unit, no source directory is a prefix of the FilePath,
we return an error code, since this is not allowed to happen.
If there are multiple matches, which is possible, we check whether any of the
components defined in the unit exposes or defines the given FilePath as a module.

=== Find the component that exposes the FilePath

A component defines the options that are necessary to compile a FilePath that
is in the component. It also defines which modules are in the component.
Therefore, we translate the given FilePath into a module name, relative to
the unit's source directory, and check if the module name is exposed by the
component. There is a special case, executables define a FilePath, for the
file that contains the 'main'-function, that is relative to the unit's source
directory.

After the component has been identified, we can actually retrieve the options
required to load and compile the given file.

== Examples

=== Mono-Repo

Assume the project structure:
  /
  └── Mono/
      ├── cabal.project
      ├── stack.yaml
      ├── A/
      │   ├── A.cabal
      │   └── Lib.hs
      └── B/
          ├── B.cabal
          └── Exe.hs

Currently, Haskell IDE Engine needs to know on startup which GHC version is
needed to compile the project. This information is needed to show warnings to
the user if the GHC version on the project does not agree with the GHC version
that was used to compile Haskell IDE Engine.

Therefore, the function 'findLocalCradle' is invoked with a dummy FilePath,
such as "/Mono/Lib.hs". Since there will be no package that contains this
dummy FilePath, the result will be a None-cradle.

Either
>>> findLocalCradle "/Mono/Lib.hs"
Cradle { cradleRootDir = "/Mono/", CradleAction { actionName = "Cabal-Helper-Stack-None", ..} }

or:
>>> findLocalCradle "/Mono/Lib.hs"
Cradle { cradleRootDir = "/Mono/", CradleAction { actionName = "Cabal-Helper-Cabal-V2-None", ..} }

The cradle result of this invocation is only used to obtain the GHC version,
which is safe, since it only checks if the cradle is a 'stack' project or
a 'cabal' project.


If we are trying to load the executable:
>>> findLocalCradle "/Mono/B/Exe.hs"
Cradle { cradleRootDir = "/Mono/B/", CradleAction { actionName = "Cabal-Helper-Cabal-V2", ..} }

we will detect correctly the compiler options, by first finding the appropriate
package, followed by traversing the units in the package and finding the
component that exposes the executable by FilePath.

=== No explicit executable folder

Assume the project structure:
  /
  └── Library/
      ├── cabal.project
      ├── stack.yaml
      ├── Library.cabal
      └── src
          ├── Lib.hs
          └── Exe.hs

There are different dependencies for the library "Lib.hs" and the
executable "Exe.hs". If we are trying to load the executable "src/Exe.hs"
we will correctly identify the executable unit, and correctly initialise
dependencies of "exe:Library".
It will be correct even if we load the unit "lib:Library" before
the "exe:Library" because the unit "lib:Library" does not expose
a module "Exe".

=== Sub package

Assume the project structure:
  /
  └── Repo/
      ├── cabal.project
      ├── stack.yaml
      ├── Library.cabal
      ├── src
      |   └── Lib.hs
      └── SubRepo
          ├── SubRepo.cabal
          └── Lib2.hs

When we try to load "/Repo/SubRepo/Lib2.hs", we need to identify root
of the project, which is "/Repo/" but set the root directory of the cradle
responsible to load "/Repo/SubRepo/Lib2.hs" to "/Repo/SubRepo", since
the compiler options obtained from Cabal-Helper are relative to the package
source directory, which is "/Repo/SubRepo".

-}
cabalHelperCradle :: FilePath -> IO Cradle
cabalHelperCradle file = do
  projM <- findCabalHelperEntryPoint file
  case projM of
    Nothing        -> do
      errorm $ "Could not find a Project for file: " ++ file
      cwd <- getCurrentDirectory
      return
        Cradle { cradleRootDir = cwd
               , cradleOptsProg =
                   CradleAction { actionName = "Cabal-Helper-None"
                                , runCradle = \_ -> return CradleNone
                                }
               }
    Just (Ex proj) -> do
      -- Find the root of the project based on project type.
      let root = projectRootDir proj
      -- Create a suffix for the cradle name.
      -- Purpose is mainly for easier debugging.
      let actionNameSuffix = projectSuffix proj
      logm $ "Cabal-Helper dirs: " ++ show [root, file]
      let dist_dir = getDefaultDistDir proj
      env <- mkQueryEnv proj dist_dir
      packages <- runQuery projectPackages env
      -- Find the package the given file may belong to.
      -- If it does not belong to any package, create a none-cradle.
      -- We might want to find a cradle without actually loading anything.
      -- Useful if we only want to determine a ghc version to use.
      case packages `findPackageFor` file of
        Nothing          -> do
          debugm $ "Could not find a package for the file: " ++ file
          debugm
            "This is perfectly fine if we only want to determine the GHC version."
          return
            Cradle { cradleRootDir = root
                   , cradleOptsProg =
                       CradleAction { actionName = "Cabal-Helper-"
                                        ++ actionNameSuffix
                                        ++ "-None"
                                    , runCradle = \_ -> return CradleNone
                                    }
                   }
        Just realPackage -> do
          debugm $ "Cabal-Helper cradle package: " ++ show realPackage
          -- Field `pSourceDir` often has the form `<cwd>/./plugin`
          -- but we only want `<cwd>/plugin`
          normalisedPackageLocation <- canonicalizePath $ pSourceDir realPackage
          debugm
            $ "Cabal-Helper normalisedPackageLocation: "
            ++ normalisedPackageLocation
          return
            Cradle { cradleRootDir = normalisedPackageLocation
                   , cradleOptsProg =
                       CradleAction { actionName =
                                        "Cabal-Helper-" ++ actionNameSuffix
                                    , runCradle = cabalHelperAction
                                        env
                                        realPackage
                                        normalisedPackageLocation
                                    }
                   }
    where

      -- | Fix occurrences of "-i." to "-i<cradle-root-dir>"
      -- Flags obtained from cabal-helper are relative to the package
      -- source directory. This is less resilient to using absolute paths,
      -- thus, we fix it here.
      fixImportDirs :: FilePath -> String -> String
      fixImportDirs base_dir arg =
        if "-i" `isPrefixOf` arg
          then let dir = drop 2 arg
          -- the flag "-i" has special meaning.
          in if not (null dir) && isRelative dir then ("-i" ++ base_dir </> dir)
                                    else arg
          else arg
          
      -- | cradle Action to query for the ComponentOptions that are needed
      -- to load the given FilePath.
      -- This Function is not supposed to throw any exceptions and use
      -- 'CradleLoadResult' to indicate errors.
      cabalHelperAction :: QueryEnv v -- ^ Query Env created by 'mkQueryEnv'
                                      -- with the appropriate 'distdir'
                        -> Package v -- ^ Package this cradle is part for.
                        -> FilePath -- ^ Root directory of the cradle
                                    -- this action belongs to.
                        -> FilePath -- ^ FilePath to load, expected to be an absolute path.
                        -> IO (CradleLoadResult ComponentOptions)
      cabalHelperAction env package root fp = do
        -- Get all unit infos the given FilePath may belong to
        let units = pUnits package
        -- make the FilePath to load relative to the root of the cradle.
        let relativeFp = makeRelative root fp
        debugm $ "Relative Module FilePath: " ++ relativeFp
        getComponent env (toList units) relativeFp
          >>= \case
            Just comp -> do
              let fs' = getFlags comp
              let fs = map (fixImportDirs root) fs'
              let targets = getTargets comp relativeFp
              let ghcOptions = fs ++ targets
              debugm $ "Flags for \"" ++ fp ++ "\": " ++ show ghcOptions
              debugm $ "Component Infos: " ++ show comp
              return
                $ CradleSuccess
                  ComponentOptions { componentOptions = ghcOptions
                                   , componentDependencies = []
                                   }
            Nothing   -> return
              $ CradleFail
              $ CradleError
                (ExitFailure 2)
                ("Could not obtain flags for " ++ fp)

-- | Get the component the given FilePath most likely belongs to.
-- Lazily ask units whether the given FilePath is part of one of their
-- component's.
-- If a Module belongs to multiple components, it is not specified which
-- component will be loaded.
-- The given FilePath must be relative to the Root of the project
-- the given units belong to.
getComponent
  :: QueryEnv pt -> [Unit pt] -> FilePath -> IO (Maybe ChComponentInfo)
getComponent _env [] _fp = return Nothing
getComponent env (unit : units) fp =
  try (runQuery (unitInfo unit) env) >>= \case
    Left (e :: IOException) -> do
      warningm $ "Catching and swallowing an IOException: " ++ show e
      warningm
        $  "The Exception was thrown in the context of finding"
        ++ " a component for \""
        ++ fp
        ++ "\" in the unit: "
        ++ show unit
      getComponent env units fp
    Right ui -> do
      let components = M.elems (uiComponents ui)
      debugm $ "Unit Info: " ++ show ui
      case find (fp `partOfComponent`) components of
        Nothing -> getComponent env units fp
        comp    -> return comp

-- | Check whether the given FilePath is part of the Component.
-- A FilePath is part of the Component if and only if:
--
--   * One Component's 'ciSourceDirs' is a prefix of the FilePath
--   * The FilePath, after converted to a module name,
--     is a in the Component's Targets, or the FilePath is
--     the executable in the component.
--
-- The latter is achieved by making the FilePath relative to the 'ciSourceDirs'
-- and then replacing Path separators with ".".
-- To check whether the given FilePath is the executable of the Component,
-- we have to check whether the FilePath, including 'ciSourceDirs',
-- is part of the targets in the Component.
partOfComponent ::
  -- | FilePath relative to the package root.
  FilePath ->
  -- | Component to check whether the given FilePath is part of it.
  ChComponentInfo ->
  Bool
partOfComponent fp' comp
  | inTargets (ciSourceDirs comp) fp' (getTargets comp fp')
  = True
  | otherwise
  = False
  where
    -- Check if the FilePath is in an executable or setup's main-is field
    inMainIs :: FilePath -> Bool
    inMainIs fp
      | ChExeEntrypoint mainIs _ <- ciEntrypoints comp = mainIs == fp
      | ChSetupEntrypoint mainIs <- ciEntrypoints comp = mainIs == fp
      | otherwise = False

    inTargets :: [FilePath] -> FilePath -> [String] -> Bool
    inTargets sourceDirs fp targets
      | Just relative <- relativeTo fp sourceDirs
      = any (`elem` targets) [getModuleName relative, fp] || inMainIs relative
      | otherwise
      = False

    getModuleName :: FilePath -> String
    getModuleName fp = map
      (\c -> if isPathSeparator c
            then '.'
            else c)
      (dropExtension fp)

-- | Get the flags necessary to compile the given component.
getFlags :: ChComponentInfo -> [String]
getFlags = ciGhcOptions

-- | Get all Targets of a Component, since we want to load all components.
-- FilePath is needed for the special case that the Component is an Exe.
-- The Exe contains a Path to the Main which is relative to some entry
-- in 'ciSourceDirs'.
-- We monkey-patch this by supplying the FilePath we want to load,
-- which is part of this component, and select the 'ciSourceDir' we actually want.
-- See the Documentation of 'ciSourceDir' to why this contains multiple entries.
getTargets :: ChComponentInfo -> FilePath -> [String]
getTargets comp fp = case ciEntrypoints comp of
  ChSetupEntrypoint {} -> []
  ChLibEntrypoint { chExposedModules, chOtherModules }
    -> map unChModuleName (chExposedModules ++ chOtherModules)
  ChExeEntrypoint { chMainIs, chOtherModules }
    -> [sourceDir </> chMainIs | Just sourceDir <- [sourceDirs]]
    ++ map unChModuleName chOtherModules
    where
      sourceDirs = find (`isFilePathPrefixOf` fp) (ciSourceDirs comp)

-- | For all packages in a project, find the project the given FilePath
-- belongs to most likely.
findPackageFor :: NonEmpty (Package pt) -> FilePath -> Maybe (Package pt)
findPackageFor packages fp = packages
  & NonEmpty.toList
  & sortOn (Down . pSourceDir)
  & filter (\p -> pSourceDir p `isFilePathPrefixOf` fp)
  & listToMaybe


projectRootDir :: ProjLoc qt -> FilePath
projectRootDir ProjLocV1CabalFile { plProjectDirV1 } = plProjectDirV1
projectRootDir ProjLocV1Dir { plProjectDirV1 } = plProjectDirV1
projectRootDir ProjLocV2File { plProjectDirV2 } = plProjectDirV2
projectRootDir ProjLocV2Dir { plProjectDirV2 } = plProjectDirV2
projectRootDir ProjLocStackYaml { plStackYaml } = takeDirectory plStackYaml

projectSuffix :: ProjLoc qt -> FilePath
projectSuffix ProjLocV1CabalFile {} = "Cabal-V1"
projectSuffix ProjLocV1Dir {} = "Cabal-V1-Dir"
projectSuffix ProjLocV2File {} = "Cabal-V2"
projectSuffix ProjLocV2Dir {} = "Cabal-V2-Dir"
projectSuffix ProjLocStackYaml {} = "Stack"

-- | The hie-bios stack cradle doesn't return the target as well, so add the
-- FilePath onto the end of the options to make sure at least one target
-- is returned.
fixCradle :: BIOS.Cradle -> BIOS.Cradle
fixCradle cradle =
  -- Normally this would also succeed for the 'Cabal-Helper-Stack' cradle.
  -- Make sure that the cradle is definitely the one created by "HIE.Bios.Cradle.loadCradle"
  if isStackCradle cradle
  then
    -- We need a lens
    cradle { BIOS.cradleOptsProg =
                (BIOS.cradleOptsProg
                  cradle) { BIOS.runCradle = \fp' -> fmap (addOption fp')
                              <$> BIOS.runCradle
                                (BIOS.cradleOptsProg cradle)
                                fp'
                          }
            }
  else cradle
  where
    addOption fp (BIOS.ComponentOptions os ds) =
      BIOS.ComponentOptions (os ++ [fp]) ds

-- ----------------------------------------------------------------------------
--
-- Utility functions to manipulate FilePath's
--
-- ----------------------------------------------------------------------------

-- | Helper function to make sure that both FilePaths are normalised.
-- Checks whether the first FilePath is a Prefix of the second FilePath.
-- Intended usage:
--
-- >>> isFilePathPrefixOf "./src/" "./src/File.hs"
-- True
--
-- >>> isFilePathPrefixOf "./src" "./src/File.hs"
-- True
--
-- >>> isFilePathPrefixOf "./src/././" "./src/File.hs"
-- True
--
-- >>> isFilePathPrefixOf "./src" "./src-dir/File.hs"
-- False
isFilePathPrefixOf :: FilePath -> FilePath -> Bool
isFilePathPrefixOf dir fp = isJust $ stripFilePath dir fp

-- | Strip the given directory from the filepath if and only if
-- the given directory is a prefix of the filepath.
--
-- >>> stripFilePath "app" "app/File.hs"
-- Just "File.hs"

-- >>> stripFilePath "src" "app/File.hs"
-- Nothing

-- >>> stripFilePath "src" "src-dir/File.hs"
-- Nothing

-- >>> stripFilePath "." "src/File.hs"
-- Just "src/File.hs"

-- >>> stripFilePath "app/" "./app/Lib/File.hs"
-- Just "Lib/File.hs"

-- >>> stripFilePath "/app/" "./app/Lib/File.hs"
-- Nothing -- Nothing since '/app/' is absolute

-- >>> stripFilePath "/app" "/app/Lib/File.hs"
-- Just "Lib/File.hs"
stripFilePath :: FilePath -> FilePath -> Maybe FilePath
stripFilePath "." fp
  | isRelative fp = Just fp
  | otherwise = Nothing
stripFilePath dir' fp'
  | Just relativeFpParts <- splitDir `stripPrefix` splitFp = Just (joinPath relativeFpParts)
  | otherwise = Nothing
  where
    dir = normalise dir'
    fp = normalise fp'
    splitFp = splitPath fp
    splitDir = splitPath dir
    stripPrefix (x:xs) (y:ys)
      | x `equalFilePath` y = stripPrefix xs ys
      | otherwise = Nothing
    stripPrefix [] ys = Just ys
    stripPrefix _ [] = Nothing

-- | Obtain all ancestors from a given directory.
--
-- >>> ancestors "a/b/c/d/e"
-- [ "a/b/c/d/e", "a/b/c/d", "a/b/c", "a/b", "a", "." ]
--
-- >>> ancestors "/a/b/c/d/e"
-- [ "/a/b/c/d/e", "/a/b/c/d", "/a/b/c", "/a/b", "/a", "/" ]
--
-- >>> ancestors "/a/b.hs"
-- [ "/a/b.hs", "/a", "/" ]
--
-- >>> ancestors "a/b.hs"
-- [ "a/b.hs", "a", "." ]
--
-- >>> ancestors "a/b/"
-- [ "a/b" ]
ancestors :: FilePath -> [FilePath]
ancestors dir
  | subdir `equalFilePath` dir = [dir]
  | otherwise = dir : ancestors subdir
  where
    subdir = takeDirectory dir

-- | Assuming a FilePath "src/Lib/Lib.hs" and a list of directories
-- such as ["src", "app"], returns either the given FilePath
-- with a matching directory stripped away.
-- If there are multiple matches, e.g. multiple directories are a prefix
-- of the given FilePath, return the first match in the list.
-- Returns Nothing, if not a single
-- given directory is a prefix of the FilePath.
--
-- >>> relativeTo "src/Lib/Lib.hs" ["src"]
-- Just "Lib/Lib.hs"
--
-- >>> relativeTo "src/Lib/Lib.hs" ["app"]
-- Nothing
--
-- >>> relativeTo "src/Lib/Lib.hs" ["src", "src/Lib"]
-- Just "Lib/Lib.hs"
relativeTo :: FilePath -> [FilePath] -> Maybe FilePath
relativeTo file sourceDirs = listToMaybe
  $ mapMaybe (`stripFilePath` file) sourceDirs
