{-# OPTIONS_HADDOCK hide #-}

module DDC.Source.Discus.Exp.Term.Pretty where
import DDC.Source.Discus.Exp.Term.Base
import DDC.Data.Pretty
import qualified Data.Text              as T


instance Pretty PrimLit where
 ppr lit
  = case lit of
        PrimLitBool     True    -> text "True"
        PrimLitBool     False   -> text "False"
        PrimLitNat      i       -> integer i
        PrimLitInt      i       -> integer i % text "i"
        PrimLitSize     s       -> integer s % text "s"
        PrimLitWord     i bits  -> integer i % text "w" % int bits
        PrimLitFloat    f bits  -> double  f % text "f" % int bits
        PrimLitChar     c       -> string (show c)
        PrimLitTextLit  tx      -> string (show $ T.unpack tx)


instance Pretty PrimVal where
 ppr val
  = case val of
        PrimValError    p       -> ppr p
        PrimValLit      lit     -> ppr lit
        PrimValArith    p       -> ppr p
        PrimValCast     p       -> ppr p
        PrimValVector   p       -> ppr p
        PrimValFun      p       -> ppr p

        PrimValElaborate
         -> text "elaborate#"

        PrimValProject l
         -> text "project#" %% ppr l

        PrimValTuple ls
         -> text "tuple#"   %% (braces $ hcat (punctuate (text ",") (map ppr ls)))

        PrimValRecord ls
         -> text "record#"  %% (braces $ hcat (punctuate (text ",") (map ppr ls)))

        PrimValVariant l
         -> text "variant#" %% ppr l

