
module DDC.Core.Llvm.Convert.Context
        ( Context       (..)
        , extendKindEnv, extendsKindEnv
        , extendTypeEnv, extendsTypeEnv

        , ExpContext    (..)
        , AltResult     (..)
        , takeVarOfContext
        , takeNonVoidVarOfContext)
where
import DDC.Core.Salt.Platform
import DDC.Core.Llvm.Metadata.Tbaa
import DDC.Core.Llvm.Convert.Base
import DDC.Type.Exp
import DDC.Llvm.Syntax
import DDC.Type.Env                     (KindEnv, TypeEnv)
import Data.Sequence                    (Seq)
import Data.Set                         (Set)
import Data.Map                         (Map)
import qualified DDC.Core.Salt          as A
import qualified DDC.Core.Module        as C
import qualified DDC.Core.Exp           as C
import qualified DDC.Type.Env           as Env


---------------------------------------------------------------------------------------------------
-- | Context of an Salt to LLVM conversion.
data Context 
        = Context
        { -- | The platform that we're converting to, 
          --   this sets the pointer width.
          contextPlatform       :: Platform

          -- | Surrounding module.
        , contextModule         :: C.Module () A.Name

          -- | The top-level kind environment.
        , contextKindEnvTop     :: KindEnv  A.Name

          -- | The top-level type environment.
        , contextTypeEnvTop     :: TypeEnv  A.Name

          -- | Names of imported supers that are defined in external modules.
          --   These are directly callable in the object code.
        , contextImports        :: Set      A.Name

          -- | Names of local supers that are defined in the current module.
          --   These are directly callable in the object code.
        , contextSupers         :: Set      A.Name

          -- | Current kind environment.
        , contextKindEnv        :: KindEnv  A.Name

          -- | Current type environment.
        , contextTypeEnv        :: TypeEnv  A.Name 

          -- | Map between Core Salt variable names and the LLVM names used to implement them.
        , contextNames          :: Map A.Name Var

          -- | Super meta data
        , contextMDSuper        :: MDSuper 

          -- | When we're converting the body of a super,
          --   holds the name of the super being converted.
        , contextSuperName       :: Maybe A.Name

          -- | When we're converting the body of a super,
          --   holds the label that we can jump to to perform a self tail-call.
        , contextSuperBodyLabel  :: Maybe Label

          -- | When we're converting the body of a super,
          --   maps names of the super parameters to the names of the shadow stack
          --   slots used to hold pointer so the associated arguments.
          --   This is used when performing a self tail-call. 
        , contextSuperParamSlots :: [(A.Name, Var)]

          -- | C library functions that are used directly by the generated code without
          --   having an import declaration in the header of the converted module.
        , contextPrimDecls       :: Map String FunctionDecl

          -- | Re-bindings of top-level supers.
          --   This is used to handle let-expressions like 'f = g [t]' where
          --   'g' is a top-level super. See [Note: Binding top-level supers]
          --   Maps the right hand variable to the left hand one, eg g -> f,
          --   along with its type arguments.
        , contextSuperBinds
                :: Map A.Name (A.Name, [C.Type A.Name])

          -- Functions to convert the various parts of the AST.
          -- We tie the recursive knot though this Context type so that
          -- we can split the implementation into separate non-recursive modules.
        , contextConvertBody 
                :: Context   -> ExpContext
                -> Seq Block -> Label
                -> Seq AnnotInstr
                -> A.Exp 
                -> ConvertM (Seq Block)

        , contextConvertExp      
                :: Context  -> ExpContext
                -> A.Exp
                -> ConvertM (Seq AnnotInstr)

        , contextConvertCase
                :: Context  -> ExpContext
                -> Label
                -> Seq AnnotInstr
                -> A.Exp
                -> [A.Alt]
                -> ConvertM (Seq Block)
        }


-- | Holds the result of converting an alternative.
data AltResult
        = AltDefault  Label (Seq Block)
        | AltCase Lit Label (Seq Block)


-- | Extend the kind environment of a context with a new binding.
extendKindEnv  :: Bind A.Name  -> Context -> Context
extendKindEnv b ctx
        = ctx { contextKindEnv = Env.extend b (contextKindEnv ctx) }


-- | Extend the kind environment of a context with some new bindings.
extendsKindEnv :: [Bind A.Name] -> Context -> Context
extendsKindEnv bs ctx
        = ctx { contextKindEnv = Env.extends bs (contextKindEnv ctx) }


-- | Extend the type environment of a context with a new binding.
extendTypeEnv  :: Bind A.Name   -> Context -> Context
extendTypeEnv b ctx
        = ctx { contextTypeEnv = Env.extend b (contextTypeEnv ctx) }


-- | Extend the type environment of a context with some new bindings.
extendsTypeEnv :: [Bind A.Name] -> Context -> Context
extendsTypeEnv bs ctx
        = ctx { contextTypeEnv = Env.extends bs (contextTypeEnv ctx) }


---------------------------------------------------------------------------------------------------
-- | What expression context we're doing this conversion in.
data ExpContext
        -- | Conversion at the top-level of a function.
        --   The expresison being converted must eventually pass control.
        = ExpTop 

        -- | In a nested context, like in the right of a let-binding.
        --   The expression should produce a value that we assign to this
        --   variable, then jump to the provided label to continue evaluation.
        | ExpNest   ExpContext Var Label

        -- | In a nested context where we need to assign the result
        --   to the given variable and fall through.
        | ExpAssign ExpContext Var


-- | Take any assignable variable from a `Context`.
takeVarOfContext :: ExpContext -> Maybe Var
takeVarOfContext context
 = case context of
        ExpTop                  -> Nothing
        ExpNest _ var _         -> Just var
        ExpAssign _ var         -> Just var


-- | Take any assignable variable from a `Context`, but only if it has a non-void type.
--   In LLVM we can't assign to void variables.
takeNonVoidVarOfContext :: ExpContext -> Maybe Var
takeNonVoidVarOfContext context
 = case takeVarOfContext context of
        Just (Var _ TVoid)       -> Nothing
        mv                       -> mv

