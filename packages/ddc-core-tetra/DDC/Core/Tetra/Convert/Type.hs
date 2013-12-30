
module DDC.Core.Tetra.Convert.Type
        ( -- * Kind conversion.
          convertK

          -- * Type conversion.
        , convertRepableT
        , convertIndexT
        , convertRegionT

          -- * Data constructor conversion.
        , convertDaCon

          -- * Bind and Bound conversion.
        , convertTypeB,  convertTypeU
        , convertValueB, convertValueU

          -- * Names
        , convertBindNameM)
where
import DDC.Core.Tetra.Convert.Boxing
import DDC.Core.Tetra.Convert.Base
import DDC.Core.Exp
import DDC.Type.Env
import DDC.Type.Compounds
import DDC.Type.Predicates
import DDC.Control.Monad.Check                  (throw)
import qualified DDC.Core.Tetra.Prim            as E
import qualified DDC.Core.Salt.Env              as A
import qualified DDC.Core.Salt.Name             as A
import qualified DDC.Core.Salt.Compounds        as A
import qualified DDC.Core.Salt.Runtime          as A
import qualified DDC.Type.Env                   as Env
import Control.Monad


-------------------------------------------------------------------------------
-- | Convert a kind from Core Tetra to Core Salt.
convertK :: Kind E.Name -> ConvertM a (Kind A.Name)
convertK kk
 = case kk of
        TCon (TyConKind kc)
          -> return $ TCon (TyConKind kc)
        _ -> throw $ ErrorMalformed "Invalid kind."


-- Type -----------------------------------------------------------------------
-- | Convert a representable type from Core Tetra to its Core Salt.
--
--   These types have kind Data and their values can be represented directly
--   in the Salt language.
--
--   Numeric types must be explicitly boxed or unboxed, that is, using 
--   (B# Nat#) or (U# Nat#), and not plain Nat#. The former two are
--   representable types, but the plain Nat# is an index type.
--
convertRepableT :: KindEnv E.Name -> Type E.Name -> ConvertM a (Type A.Name)
convertRepableT kenv tt
 = case tt of
        -- Convert type variables and constructors.
        TVar u
         -> case Env.lookup u kenv of
             Just t
              | isDataKind t 
              -> liftM TVar $ convertTypeU u

              | otherwise    
              -> throw $ ErrorMalformed "Repable type does not have kind Data."

             Nothing 
              -> throw $ ErrorInvalidBound u

        -- Convert unapplied type constructors.
        TCon{}  -> convertTyConApp kenv tt

        -- We pass quantifiers of Data and Region variables to the Salt
        -- language, but strip off the rest.
        TForall b t     
         | isDataKind (typeOfBind b) || isRegionKind (typeOfBind b)
         -> do  let kenv' = Env.extend b kenv
                b'      <- convertTypeB    b
                t'      <- convertRepableT kenv' t
                return  $ TForall b' t'

         |  otherwise
         -> do  let kenv' = Env.extend b kenv
                convertRepableT kenv' t

        -- Convert applications.
        TApp{}  -> convertTyConApp kenv tt

        -- Resentable types always have kind Data, but type sums cannot.
        TSum{}  -> throw $ ErrorUnexpectedSum


-- | Convert the application of a type constructor to Salt form.
convertTyConApp :: KindEnv E.Name -> Type E.Name -> ConvertM a (Type A.Name)
convertTyConApp kenv tt
         -- Convert Tetra function types to Salt function types.
         | Just (t1, t2)                       <- takeTFun tt
         = do   t1'     <- convertRepableT kenv t1
                t2'     <- convertRepableT kenv t2
                return  $ tFunPE t1' t2'
         
         -- Explicitly Boxed numeric types.
         --   In Salt, boxed numeric values are represented in generic form,
         --   as pointers to objects in the top-level region.
         | Just ( E.NameTyConTetra E.TyConTetraB 
                , [tBIx])                      <- takePrimTyConApps tt
         , isBoxableIndexType tBIx
         =      return  $ A.tPtr A.rTop A.tObj       

         -- Explicitly Unboxed numeric types.
         --   In Salt, unboxed numeric values are represented directly as 
         --   values of the corresponding machine type.
         | Just ( E.NameTyConTetra E.TyConTetraU
                , [tBIx])                      <- takePrimTyConApps tt
         , isBoxableIndexType tBIx
         = do   tBIx'   <- convertIndexT tBIx
                return tBIx'

         -- Generic data types are represented in boxed form.   
         | Just (_, tR : _args)                <- takeTyConApps tt
         = do   tR'     <- convertRegionT kenv tR
                return  $ A.tPtr tR' A.tObj
         
         | otherwise
         =      throw $ ErrorMalformed $ "Invalid type constructor application."
        

-- | Convert an index type from Tetra to Salt.
--   
--   In Tetra types like Nat# are used as type indices to specifify
--   a boxed representation (B# Nat) or unboxed representation (U# Nat#).
--
convertIndexT :: Type E.Name -> ConvertM a (Type A.Name)
convertIndexT tt
        | Just (E.NamePrimTyCon n, [])  <- takePrimTyConApps tt
        = case n of
                E.PrimTyConNat          -> return $ A.tNat
                E.PrimTyConInt          -> return $ A.tInt
                E.PrimTyConWord  bits   -> return $ A.tWord bits
                E.PrimTyConFloat bits   -> return $ A.tWord bits
                _ -> throw  $ ErrorMalformed "Invalid numeric index type."

        | otherwise
        = throw $ ErrorMalformed "Invalid numeric index type."


-- | Convert a region type to Salt.
convertRegionT :: KindEnv E.Name -> Type E.Name -> ConvertM a (Type A.Name)
convertRegionT kenv tt
        | TVar u        <- tt
        , Just k        <- Env.lookup u kenv
        , isRegionKind k
        = liftM TVar $ convertTypeU u

        | otherwise
        = throw $ ErrorMalformed "Invalid region type."


-- Binds ----------------------------------------------------------------------
-- | Convert a type binder.
--   These are formal type parameters.
convertTypeB    :: Bind E.Name -> ConvertM a (Bind A.Name)
convertTypeB bb
 = case bb of
        BNone k         -> liftM  BNone (convertK k)
        BAnon k         -> liftM  BAnon (convertK k)
        BName n k       -> liftM2 BName (convertBindNameM n) (convertK k)


-- | Convert the value binder.
--   These are used to bind function arguments, for let-bindings,
--   and hence must have representable types.
convertValueB   :: KindEnv E.Name -> Bind E.Name -> ConvertM a (Bind A.Name)
convertValueB kenv bb
  = case bb of
        BNone t         -> liftM  BNone (convertRepableT kenv t)        
        BAnon t         -> liftM  BAnon (convertRepableT kenv t)
        BName n t       -> liftM2 BName (convertBindNameM n) 
                                        (convertRepableT kenv t)

-- | Convert the name of a Bind.
convertBindNameM :: E.Name -> ConvertM a A.Name
convertBindNameM nn
 = case nn of
        E.NameVar str   -> return $ A.NameVar str
        _               -> throw $ ErrorInvalidBinder nn


-- Bounds ---------------------------------------------------------------------
-- | Convert a type bound.
--   These are bound by formal type parametrs.
convertTypeU    :: Bound E.Name -> ConvertM a (Bound A.Name)
convertTypeU uu
 = case uu of
        UIx i                   
          -> return $ UIx i

        UName (E.NameVar str)   
          -> return $ UName (A.NameVar str)

        -- There are no primitive type variables,
        -- so we don't need to handle the UPrim case.
        _ -> throw $ ErrorInvalidBound uu


-- | Convert a value bound.
--   These refer to function arguments or let-bound values, 
--   and hence must have representable types.
convertValueU :: Bound E.Name -> ConvertM a (Bound A.Name)
convertValueU uu
  = case uu of
        UIx i                   
         -> return $ UIx i

        UName (E.NameVar str)   
         -> return $ UName (A.NameVar str)

        -- When converting primops, use the type directly specified by the 
        -- Salt language instead of converting it from Tetra. The types from
        -- each language definition may not be inter-convertible.
        UPrim n _
         -> case n of
                E.NamePrimArith op      
                  -> return $ UPrim (A.NamePrimOp (A.PrimArith op)) 
                                    (A.typeOfPrimArith op)

                E.NamePrimCast op
                  -> return $ UPrim (A.NamePrimOp (A.PrimCast  op)) 
                                    (A.typeOfPrimCast  op)

                _ -> throw $ ErrorInvalidBound uu

        _ -> throw $ ErrorInvalidBound uu


-- DaCon ----------------------------------------------------------------------
-- | Convert a data constructor definition.
convertDaCon :: KindEnv E.Name -> DaCon E.Name -> ConvertM a (DaCon A.Name)
convertDaCon kenv dc
 = case dc of
        DaConUnit       
         -> return DaConUnit

        DaConPrim n t
         -> do  n'      <- convertDaConNameM dc n
                t'      <- convertRepableT   kenv t
                return  $ DaConPrim
                        { daConName             = n'
                        , daConType             = t' }

        DaConBound n
         -> do  n'      <- convertDaConNameM dc n
                return  $ DaConBound
                        { daConName             = n' }


-- | Convert the name of a data constructor.
convertDaConNameM :: DaCon E.Name -> E.Name -> ConvertM a A.Name
convertDaConNameM dc nn
 = case nn of
        E.NameLitBool val       -> return $ A.NameLitBool val
        E.NameLitNat  val       -> return $ A.NameLitNat  val
        E.NameLitInt  val       -> return $ A.NameLitInt  val
        E.NameLitWord val bits  -> return $ A.NameLitWord val bits
        _                       -> throw $ ErrorInvalidDaCon dc
