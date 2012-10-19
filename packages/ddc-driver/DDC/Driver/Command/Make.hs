
module DDC.Driver.Command.Make
        (cmdMake)
where
import DDC.Driver.Stage
import DDC.Driver.Source
import DDC.Build.Pipeline
import DDC.Build.Language
import System.Directory
import Control.Monad
import Data.List
import qualified DDC.Core.Pretty        as P


cmdMake :: Config -> FilePath -> IO ()
cmdMake config filePath
 = do
        -- Read in the source file.
        exists  <- doesFileExist filePath
        when (not exists)
         $      error $ "No such file " ++ show filePath

        src             <- readFile filePath
        let source      = SourceFile filePath

        -- Decide what to do based on file extension.
        let make
                -- Make a Core Lite module.
                | isSuffixOf ".dcl" filePath
                = pipeText (nameOfSource source) (lineStartOfSource source) src
                $ stageLiteLoad     config source
                [ stageLiteOpt      config source  
                [ stageLiteToSalt   config source 
                [ stageSaltOpt      config source
                [ stageSaltToLLVM   config source 
                [ stageCompileLLVM  config source filePath True ]]]]]

                -- Make a Core Salt module.
                | isSuffixOf ".dce" filePath
                = pipeText (nameOfSource source) (lineStartOfSource source) src
                $ PipeTextLoadCore  fragmentSalt 
                [ stageSaltOpt      config source
                [ stageSaltToLLVM   config source 
                [ stageCompileLLVM  config source filePath True ]]]

                -- Unrecognised.
                | otherwise
                = error $ "Don't know how to make " ++ filePath

        -- Print any errors that arose during compilation.
        errs    <- make
        mapM_ (putStrLn . P.renderIndent . P.ppr) errs