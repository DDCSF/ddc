-- | Compiler stages.
--
--   A compiler 'stage' is a compound pipeline that depends on DDCI specific
--   configuration information. 
--
--   This is where we select optimisation passes based on command line
--   flags, and dump the intermediate representation after the various transforms.
--
--   These stages are then invoked by the DDCI commands.
--
module DDCI.Core.Stage
        ( stageLiteLoad
        , stageLiteOpt
        , stageLiteToSalt
        , stageSaltToC
        , stageSaltToLLVM
        , stageCompileLLVM)
where
import DDCI.Core.State
import DDC.Build.Builder
import DDC.Build.Pipeline
import DDC.Build.Language
import DDC.Core.Transform.Namify
import DDC.Core.Module
import DDC.Core.Exp
import Control.Monad
import System.FilePath
import Data.Monoid
import Data.Maybe
import Data.List
import qualified DDC.Build.Language.Salt        as Salt
import qualified DDC.Build.Language.Lite        as Lite
import qualified DDC.Core.Simplifier            as S
import qualified DDC.Core.Lite                  as Lite
import qualified DDC.Core.Salt.Name             as Salt
import qualified DDC.Core.Check                 as C
import qualified Data.Set                       as Set
import qualified Data.Map                       as Map

------------------------------------------------------------------------------
-- | If the Dump mode is set 
--    then produce a SinkFile to write a module to a file, 
--    otherwise produce SinkDiscard to drop it on the floor.
dump :: State -> Source -> String -> Sink
dump state source dumpFile 
        | Set.member Dump $ stateModes state
        = let   outputDir
                 | SourceFile filePath  <- source
                 = fromMaybe (takeDirectory filePath) 
                             (stateOutputDir state)

                 | otherwise
                 = fromMaybe "."
                             (stateOutputDir state)

          in    SinkFile $ outputDir </> dumpFile

        | otherwise
        = SinkDiscard


-------------------------------------------------------------------------------
-- | Load Lite.
stageLiteLoad
        :: State -> Source
        -> [PipeCore (C.AnTEC () Lite.Name) Lite.Name]
        -> PipeText Lite.Name Lite.Error

stageLiteLoad state source pipesLite
 = PipeTextLoadCore fragmentLite
    ( PipeCoreOutput (dump state source "dump.lite-load.dcl")
    : pipesLite )


-------------------------------------------------------------------------------
-- | Optimise Lite.
stageLiteOpt 
        :: State -> Source
        -> [PipeCore (C.AnTEC () Lite.Name) Lite.Name]
        -> PipeCore  (C.AnTEC () Lite.Name) Lite.Name

stageLiteOpt state source pipes
 = PipeCoreSimplify 
        (0 :: Int) 

        -- TODO: want to see every intermediate stage.
        -- TODO: want to do a fixpoint.
        (  (S.Trans $ S.Inline 
                    $ lookupTemplateFromModules
                        (Map.elems (stateWithLite state)))

        -- hrm. Want a fixpoint here.
        <> S.Trans S.Beta <> S.Trans S.Flatten <> normalizeLite <> S.Trans S.Forward
        <> S.Trans S.Beta <> S.Trans S.Flatten <> normalizeLite <> S.Trans S.Forward
        <> S.Trans S.Beta <> S.Trans S.Flatten <> normalizeLite <> S.Trans S.Forward
        <> S.Trans S.Beta <> S.Trans S.Flatten <> normalizeLite <> S.Trans S.Forward
        <> normalizeLite
        )

        -- TODO: Inlining isn't preserving type annots, 
        --       so need to recheck the module before Lite -> Salt conversion.
        [ PipeCoreOutput (dump state source "dump.lite-opt.dcl")
        , PipeCoreReCheck fragmentLite pipes ]

 where  normalizeLite
         = S.anormalize
                (makeNamifier Lite.freshT)      
                (makeNamifier Lite.freshX)


-- TODO: Rubbish function to load inliner templates from some modules.
--       It just does a linear search, which won't be good enough in the long-term.
lookupTemplateFromModules 
        :: Eq n
        => [Module a n] -> n -> Maybe (Exp a n)

lookupTemplateFromModules [] _  = Nothing
lookupTemplateFromModules (m:ms) n
 = case lookupTemplateFromModule m n of
        Nothing -> lookupTemplateFromModules ms n
        Just x  -> Just x


lookupTemplateFromModule 
        :: Eq n
        => Module a n -> n -> Maybe (Exp a n)

lookupTemplateFromModule mm n
        | XLet _ (LRec bxs) _  <- moduleBody mm
        = liftM snd $ find (\(BName n' _, _) -> n == n') bxs

        | otherwise
        = Nothing


-------------------------------------------------------------------------------
-- | Convert Lite to Salt.
--   
--   Result is a-normalised.
--
stageLiteToSalt 
        :: State -> Source -> Builder
        -> [PipeCore (C.AnTEC () Salt.Name) Salt.Name] 
        -> PipeCore  (C.AnTEC () Lite.Name) Lite.Name

stageLiteToSalt state source builder pipesSalt
 = PipeCoreAsLite 
   [ PipeLiteToSalt       (buildSpec builder)
     [ PipeCoreOutput     (dump state source "dump.lite-to-salt.dce")
     , PipeCoreSimplify   0
                (S.anormalize (makeNamifier Salt.freshT)
                              (makeNamifier Salt.freshX))
       [ PipeCoreOutput   (dump state source "dump.salt-normalized.dce")
       , PipeCoreCheck    fragmentSalt
         pipesSalt]]]


-- | Convert Salt to C code.
stageSaltToC
        :: State -> Source -> Builder
        -> Sink
        -> PipeCore (C.AnTEC () Salt.Name) Salt.Name

stageSaltToC state source _builder sink
 = PipeCoreSimplify 0
        (stateSimplSalt state 
                <> S.anormalize (makeNamifier Salt.freshT) 
                                (makeNamifier Salt.freshX))
   [ PipeCoreOutput       (dump state source "dump.salt-simplified.dce")
   , PipeCoreCheck        fragmentSalt
     [ PipeCoreAsSalt
       [ PipeSaltTransfer
         [ PipeSaltOutput (dump state source "dump.salt-transfer.dce")
         , PipeSaltPrint  
                (Set.member SaltPrelude (stateModes state))
                sink]]]]


-- | Convert Salt to LLVM.
stageSaltToLLVM
        :: State -> Source -> Builder
        -> [PipeLlvm]
        -> PipeCore (C.AnTEC () Salt.Name) Salt.Name

stageSaltToLLVM state source builder pipesLLVM
 = PipeCoreSimplify 0
        (stateSimplSalt state
                <> S.anormalize (makeNamifier Salt.freshT)
                                (makeNamifier Salt.freshX))
   [ PipeCoreOutput         (dump state source "dump.salt-simplified.dce")
   , PipeCoreCheck          fragmentSalt
     [ PipeCoreAsSalt
       [ PipeSaltTransfer
         [ PipeSaltOutput   (dump state source "dump.salt-transfer.dce")
         , PipeSaltToLlvm   (buildSpec builder) 
           ( PipeLlvmPrint  (dump state source "dump.salt-to-llvm.ll")
           : pipesLLVM) ]]]]


-- | Compile LLVM code.
stageCompileLLVM 
        :: State -> Source -> Builder 
        -> FilePath             -- ^ Path of original source file.
                                --   Build products are placed into the same dir.
        -> Bool                 -- ^ Should we link this into an executable
        -> PipeLlvm

stageCompileLLVM state _source builder filePath shouldLinkExe
 = let  -- Decide where to place the build products.
        outputDir      = fromMaybe (takeDirectory filePath) (stateOutputDir state)
        outputDirBase  = dropExtension (replaceDirectory filePath outputDir)
        llPath         = outputDirBase ++ ".ddc.ll"
        sPath          = outputDirBase ++ ".ddc.s"
        oPath          = outputDirBase ++ ".o"
        exePathDefault = outputDirBase
        exePath        = fromMaybe exePathDefault (stateOutputFile state)
   in   -- Make the pipeline for the final compilation.
        PipeLlvmCompile
          { pipeBuilder           = builder
          , pipeFileLlvm          = llPath
          , pipeFileAsm           = sPath
          , pipeFileObject        = oPath
          , pipeFileExe           = if shouldLinkExe 
                                        then Just exePath 
                                        else Nothing }

