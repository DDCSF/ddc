{-# OPTIONS -O2 #-}

module Source.Parser.Util
	( Var		-- from Shared.Var
	, (<|>)		-- from Parsec
	, (<?>)		-- from Parsec

	, SP, Parser

	-- Variable Creation
	, toVar
	, makeVar

	-- NameSpace Utils
	, vNameDefaultN
	, kindOfVarSpace

	-- Source Positions
	, spV, spTP, spX, spW

	-- Parsing Combinators
	, makeParsecSourcePos

	-- Debugging
	, traceStateS, traceState)
where
import Type.Exp
import Source.Util
import Source.Exp
import Shared.Error
import DDC.Base.SourcePos
import Shared.Var					(Var, NameSpace(..))
import Text.ParserCombinators.Parsec.Prim		( (<|>), (<?>) )
import qualified Source.Token 				as K
import qualified Shared.Var				as Var
import qualified Text.ParserCombinators.Parsec.Prim	as Parsec
import qualified Text.ParserCombinators.Parsec.Pos	as Parsec
import qualified Debug.Trace

-----
stage	= "Source.Parser.Util"

----
type SP		= SourcePos
type Parser 	= Parsec.GenParser K.TokenP ()

-- Variable Creation -------------------------------------------------------------------------------
-- | Convert a token to a variable
--	We need to undo the lexer tokens here because some of our
--	"reserved symbols" alias with valid variable names.
--
toVar :: K.TokenP -> Var
toVar	 tok
 = case K.token tok of
	K.Var    	name	-> Var.loadSpaceQualifier $ makeVar name tok
	K.VarField	name	-> (makeVar name tok) { Var.nameSpace = NameField }
	K.Con		name	-> Var.loadSpaceQualifier $ makeVar name tok
	K.Symbol 	name	-> makeVar name tok
	_ -> case lookup (K.token tok) toVar_table of
		Just name	-> makeVar name tok
		Nothing		-> panic stage ("toVar: bad token: " ++ show tok)


-- | String representations for these tokens.
toVar_table :: [(K.Token, String)]
toVar_table =
	[ (K.Colon,		":")
	, (K.Star,		"*")
	, (K.Dash,		"-")
	, (K.At,		"@")
	, (K.Hash,		"#")
	, (K.ABra,		"<")
	, (K.AKet,		">")
	, (K.ForwardSlash,	"/")
	, (K.Plus,		"+")
	, (K.Dot,		".")
	, (K.Dollar,		"$")
	, (K.Tilde,		"~")
	, (K.Percent,		"%") ]

-- | Make a variable with this name,
--	using the token as the source location for the var.
makeVar :: String -> K.TokenP -> Var
makeVar    name@(n:_) tok
 = let 	sp	= SourcePos (K.tokenFile tok, K.tokenLine tok, K.tokenColumn tok)
   in	(Var.new name)
	 	{ Var.info	= [ Var.ISourcePos sp ] }



-- | If the var has no namespace set, then give it this one.
vNameDefaultN	:: NameSpace -> Var -> Var
vNameDefaultN space var
 = case Var.nameSpace var of
 	NameNothing	-> var { Var.nameSpace = space }
	_		-> var

-- | Decide on the kind of a type var from it's namespace
kindOfVarSpace :: NameSpace -> Kind
kindOfVarSpace space
 = case space of
 	NameNothing	-> kValue
	NameRegion	-> kRegion
	NameEffect	-> kEffect
	NameClosure	-> kClosure
	NameType	-> kValue
	_		-> panic stage $ "kindOfVarSpace: no kind for " ++ show space

-- | Slurp the source position from this token.
spTP :: K.TokenP -> SP
spTP    tok
	= SourcePos (K.tokenFile tok, K.tokenLine tok, K.tokenColumn tok)


-- Source Positions --------------------------------------------------------------------------------
-- | Slurp the source position from this expression.
spX :: Exp SP -> SP
spX 	= sourcePosX


-- | Slurp the source position from this pattern.
spW	= sourcePosW

-- | Slurp the source position from this variable.
spV :: Var -> SP
spV var
 = let	[sp]	= [sp | Var.ISourcePos sp <- Var.info var]
   in	sp


makeParsecSourcePos :: K.TokenP -> Parsec.SourcePos
makeParsecSourcePos tok
	= flip Parsec.setSourceColumn (K.tokenColumn tok)
	$ flip Parsec.setSourceLine   (K.tokenLine tok)
	$ Parsec.initialPos      (K.tokenFile tok)


-- Debugging ---------------------------------------------------------------------------------------

traceStateS :: Show tok => String -> Parsec.GenParser tok st ()
traceStateS str
 = do	state	<- Parsec.getParserState
	Debug.Trace.trace
		(  "-- state " ++ str ++ "\n"
		++ "   input = " ++ show (take 10 $ Parsec.stateInput state) ++ "\n")
		$ return ()

traceState :: Show tok => Parsec.GenParser tok st ()
traceState = traceStateS ""


