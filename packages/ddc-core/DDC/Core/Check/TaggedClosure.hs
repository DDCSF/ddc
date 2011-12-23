
module DDC.Core.Check.TaggedClosure
        ( TaggedClosure(..)
        , closureOfTagged
        , closureOfTaggedSet
        , taggedClosureOfValBound
        , taggedClosureOfTyArg)
where
import DDC.Type.Operators.Trim
import DDC.Type.Compounds
import DDC.Type.Predicates
import DDC.Type.Pretty
import DDC.Type.Exp
import Data.Set                 (Set)
import qualified DDC.Type.Sum   as Sum
import qualified Data.Set       as Set

-- TaggedClosure --------------------------------------------------------------
-- | A closure tagged with the bound variable that the closure term is due to.
data TaggedClosure n
        = GBoundVal    (Bound n) (TypeSum n)
        | GBoundRgnVar (Bound n)
        | GBoundRgnCon (Bound n)
        deriving Show


instance Eq n  => Eq (TaggedClosure n) where
 (==)    (GBoundVal u1 _)  (GBoundVal u2 _)     = u1 == u2
 (==)    (GBoundRgnVar u1) (GBoundRgnVar u2)    = u1 == u2
 (==)    (GBoundRgnCon u1) (GBoundRgnCon u2)    = u1 == u2
 (==)    _                 _                    = False
 

instance Ord n => Ord (TaggedClosure n) where
 compare g1 g2 = compare (ordify g1) (ordify g2)
  where 
        ordify gg
         = case gg of
                GBoundVal u _   -> (0, u) :: (Int, Bound n)
                GBoundRgnVar u  -> (1, u)
                GBoundRgnCon u  -> (2, u)


instance (Eq n, Pretty n) => Pretty (TaggedClosure n) where
 ppr cc
  = case cc of
        GBoundVal    u clos -> text "CLOVAL   " <+> ppr u <+> text ":" <+> ppr clos
        GBoundRgnVar u      -> text "CLORGNVAR" <+> ppr u
        GBoundRgnCon u      -> text "CLORGNCON" <+> ppr u


-- | Convert a tagged clousure to a regular closure by dropping the tag variables.
closureOfTagged :: TaggedClosure n -> Closure n
closureOfTagged gg
 = case gg of
        GBoundVal _ clos  -> TSum $ clos
        GBoundRgnVar u    -> tUse (TVar u)
        GBoundRgnCon u    -> tUse (TCon (TyConBound u))


-- | Convert a set of tagged closures to a regular closure by dropping the
--   tag variables.
closureOfTaggedSet :: Ord n => Set (TaggedClosure n) -> Closure n
closureOfTaggedSet clos
        = TSum  $ Sum.fromList kClosure 
                $ map closureOfTagged 
                $ Set.toList clos


-- | Take the tagged closure of a value variable.
taggedClosureOfValBound :: (Ord n, Pretty n) => Bound n -> TaggedClosure n
taggedClosureOfValBound u
        = GBoundVal u 
        $ Sum.singleton kClosure 
        $ trimClosure $ tDeepUse $ typeOfBound u


-- | Take the tagged closure of a type argument.
taggedClosureOfTyArg :: (Ord n, Pretty n) => Type n -> Set (TaggedClosure n)
taggedClosureOfTyArg tt
 = case tt of
        TVar u
         |   isRegionKind (typeOfBound u)
         ->  Set.singleton $ GBoundRgnVar u

        TCon (TyConBound u)
         |   isRegionKind (typeOfBound u)
         ->  Set.singleton $ GBoundRgnCon u

        _ -> Set.empty
