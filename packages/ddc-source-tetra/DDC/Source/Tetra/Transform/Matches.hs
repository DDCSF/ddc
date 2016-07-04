{-# LANGUAGE TypeFamilies, OverloadedStrings #-}

-- | Desugar match expressions to case expressions.
--
--   In a match expression if matching fails in one block of guards then
--   we skip to the next block. This introduces join point at the start
--   of every block of guards execpt the first one, which we need to flatten
--   out when converting to plain case expressions.
--
--   We also merge multiple clauses for the same function into a single one 
--   while we're here.
-- 
module DDC.Source.Tetra.Transform.Matches
        ( type S, evalState, newVar
        , desugarModule)
where
import DDC.Source.Tetra.Module
import DDC.Source.Tetra.Prim
import DDC.Source.Tetra.Exp
import DDC.Source.Tetra.Transform.BoundX
import Data.Monoid
import Data.Text                        (Text)
import qualified DDC.Data.SourcePos     as SP
import qualified Control.Monad.State    as S
import qualified Data.Text              as Text


-------------------------------------------------------------------------------
-- | Source position.
type SP = SP.SourcePos


-- | State holding a variable name prefix and counter to 
--   create fresh variable names.
type S  = S.State (Text, Int)


-- | Evaluate a desguaring computation,
--   using the given prefix for freshly introduced variables.
evalState :: Text -> S a -> a
evalState n c
 = S.evalState c (n, 0) 


-- | Allocate a new named variable, yielding its associated bind and bound.
newVar :: Text -> S (Bind, Bound)
newVar pre
 = do   (n, i)   <- S.get
        let name = pre <> "$" <> n <> Text.pack (show i)
        S.put (n, i + 1)
        return  (BName name, UName name)


-------------------------------------------------------------------------------
-- | Desugar match expressions to case expressions in a module.
desugarModule :: Module Source -> S (Module Source)
desugarModule mm
 = do   ts'     <- desugarTops $ moduleTops mm
        return  $  mm { moduleTops = ts' }



-------------------------------------------------------------------------------
-- | Desugar top-level definitions.
desugarTops :: [Top Source] -> S [Top Source]
desugarTops ts
 = do   let tsType  = [t          | t@TopType{}     <- ts]
        let tsData  = [t          | t@TopData{}     <- ts]
        let spCls   = [(sp, cl)   | TopClause sp cl <- ts]

        spCls'  <- desugarClGroup spCls

        return  $  tsType
                ++ tsData 
                ++ [TopClause sp cl | (sp, cl) <- spCls']


-------------------------------------------------------------------------------
-- | Desugar a clause group.
desugarClGroup :: [(SP, Clause)] -> S [(SP, Clause)]
desugarClGroup spcls0
 = loop spcls0
 where

  -- We've reached the end of the list of clauses.
  loop []
   = return []

  -- Signatures do not need desugaring.
  loop ((sp, cl@SSig{}) : cls) 
   = do cls'    <- loop cls
        return  $  (sp, cl) : cls'

  -- We have a let-clause.
  loop ( (sp, SLet sp1 (XBindVarMT b1 mt1) ps1 gxs1) : cls)
   = loop cls >>= \cls'
   -> case cls' of

        -- Consecutive clauses are for the same function.
        (_, SLet _sp2 (XBindVarMT b2 _mt2) ps2 [GExp xNext]) : clsRest
          | b1 == b2
          -> do  
                -- Desugar the inner guarded expressions.
                xBody_inner <- flattenGXs gxs1 xNext
                xBody_rec   <- desugarX sp xBody_inner

                (ps1', _ps2', xBody_join) 
                            <- joinParams ps1 ps2 xBody_rec

                return  $ (sp, SLet sp1 (XBindVarMT b1 mt1) ps1'
                                        [GExp xBody_join])
                        : clsRest

        -- Consecutive clauses are not for the same function.
        _ -> do let xError  = makeXErrorDefault
                                (Text.pack    $ SP.sourcePosSource sp1)
                                (fromIntegral $ SP.sourcePosLine   sp1)

                -- Desugar the inner guarded expressions.
                xBody_inner <- flattenGXs gxs1 xError
                xBody'      <- desugarX sp xBody_inner

                return  $ (sp, SLet sp1 (XBindVarMT b1 mt1) ps1
                                        [GExp xBody'])
                        : cls'


joinParams ::    [Param] -> [Param] -> Exp 
           -> S ([Param],   [Param],   Exp)

joinParams []   ps2  xx 
 = return ([],  ps2, xx)

joinParams ps1  []   xx 
 = return (ps1, [],  xx)

joinParams (p1:ps1) (p2:ps2) xx
 = do
        (p1',  p2',  mLets) <- joinParam  p1 p2 
        (ps1', ps2', xx')   <- joinParams ps1 ps2 xx

        case mLets of
         Nothing
          -> return (p1' : ps1', p2' : ps2', xx')

         Just lts
          -> return (p1' : ps1', p2' : ps2', XLet lts xx')


-- | TODO: if the first param does not have a name but the second one does
--         not then create a new one. do not swap as we the name might
--         be shadowing another.
joinParam :: Param -> Param 
          -> S (Param, Param, Maybe Lets)

joinParam p1 p2
 = case (p1, p2) of
        (  MValue (PVar (BName n1)) _mt1
         , MValue (PVar (BName n2)) mt2)
         |   n1 /= n2
         ->  let lts  = LLet (XBindVarMT (BName n2) mt2) (XVar (UName n1))
             in  return (p1, p2, Just $ lts)

         |   otherwise
         ->  return (p1, p2, Nothing)

        _ -> return (p1, p2, Nothing)


-------------------------------------------------------------------------------
-- | Desugar an expression.
desugarX :: SP -> Exp -> S Exp
desugarX sp xx
 = case xx of
        -- Boilerplate.
        XAnnot sp' x    -> XAnnot sp' <$> desugarX sp' x
        XVar{}          -> pure xx
        XPrim{}         -> pure xx
        XCon{}          -> pure xx
        XLam  b x       -> XLam b     <$> pure x
        XLAM  b x       -> XLAM b     <$> pure x
        XApp  x1 x2     -> XApp       <$> desugarX   sp x1  <*> desugarX sp x2
        XLet  lts x     -> XLet       <$> desugarLts sp lts <*> desugarX sp x
        XCast c x       -> XCast c    <$> desugarX   sp x
        XType{}         -> pure xx
        XWitness{}      -> pure xx
        XDefix a xs     -> XDefix a   <$> mapM (desugarX sp)  xs
        XInfixOp{}      -> pure xx
        XInfixVar{}     -> pure xx

        XCase x alts    
         -> XCase  <$> desugarX sp x  
                   <*> mapM (desugarAC sp) alts

        XMatch _ alts xFail
         -> do  let gxs =  [gx | AAltMatch gx <- alts]
                xFlat   <- flattenGXs gxs xFail
                xFlat'  <- desugarX sp xFlat
                return  xFlat'


-------------------------------------------------------------------------------
-- | Desugar some let bindings.
desugarLts :: SP -> Lets -> S Lets
desugarLts sp lts
 = case lts of
        LLet mb x       -> LLet mb  <$> desugarX sp x

        LRec bxs
         -> do  let (bs, xs)    = unzip bxs
                xs'             <- mapM (desugarX sp) xs
                return $ LRec $ zip bs xs'

        LPrivate{}      -> return lts

        LGroup cls
         -> do  let spcls  =  zip (repeat sp) cls
                spcls'     <- desugarClGroup spcls
                return     $ LGroup $ map snd spcls'


-------------------------------------------------------------------------------
-- | Desugar a guarded expression.
desugarGX :: SP -> GuardedExp -> S GuardedExp
desugarGX sp gx 
 = case gx of
        GGuard g gx'    -> GGuard <$> desugarG sp g <*> desugarGX sp gx'
        GExp   x        -> GExp   <$> desugarX sp x


-------------------------------------------------------------------------------
-- | Desugar a guard.
desugarG :: SP -> Guard -> S Guard
desugarG sp g
 = case g of
        GPat p x        -> GPat p  <$> desugarX sp x
        GPred x         -> GPred   <$> desugarX sp x
        GDefault        -> pure GDefault


-------------------------------------------------------------------------------
-- | Desugar a case alternative.
desugarAC :: SP -> AltCase -> S AltCase
desugarAC sp (AAltCase p gxs)
 = do   gxs'    <- mapM (desugarGX sp) gxs
        return  $  AAltCase p gxs'


-------------------------------------------------------------------------------
-- | Desugar some guards to a case-expression.
--   At runtime, if none of the guards match then run the provided
--   fail action.
flattenGXs
        :: [GuardedExp] -- ^ Guarded expressions to desugar.
        -> Exp          -- ^ Failure action.
        -> S Exp 

flattenGXs gs0 fail0
 = go gs0 fail0
 where
        -- Desugar list of guarded expressions.
        go [] cont
         = return cont

        go [g]   cont
         = go1 g cont

        go (g : gs) cont
         = do   gs'     <- go gs cont
                go1 g gs'

        -- Desugar single guarded expression.
        go1 (GExp x1) _
         = return x1

        go1 (GGuard GDefault   gs) cont
         = go1 gs cont

        -- Simple cases where we can avoid introducing the continuation.
        go1 (GGuard (GPred g1)   (GExp x1)) cont
         = return 
         $ XCase g1
                [ AAltCase PTrue    [GExp x1]
                , AAltCase PDefault [GExp cont] ]

        go1 (GGuard (GPat p1 g1) (GExp x1)) cont
         = return
         $ XCase g1
                [ AAltCase p1        [GExp x1]
                , AAltCase PDefault  [GExp cont]]

        -- Cases that use a continuation function as a join point.
        -- We need this when desugaring general pattern alternatives,
        -- as each group of guards can be reached from multiple places.
        go1 (GGuard (GPred x1) gs) cont
         = do   (b, u)  <- newVar "m"
                x'      <- go1 (liftX 1 gs) (XRun (XVar u))
                return
                 $ XLet  (LLet (XBindVarMT b Nothing) (XBox cont))
                 $ XCase (liftX 1 x1)
                       [ AAltCase PTrue    [GExp x']
                       , AAltCase PDefault [GExp (XRun (XVar u)) ]]

        go1 (GGuard (GPat p1 x1) gs) cont
         = do   (b, u)  <- newVar "m"
                x'      <- go1 (liftX 1 gs) (XRun (XVar u))
                return
                 $ XLet  (LLet (XBindVarMT b Nothing) (XBox cont))
                 $ XCase (liftX 1 x1)
                        [ AAltCase p1       [GExp x']
                        , AAltCase PDefault [GExp (XRun (XVar u)) ]]
