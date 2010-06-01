{-# OPTIONS -O2 #-}

module Source.Parser.Type
	( pSuper
	, pKind
	, pType, pType_body, pType_body1, pTypeOp)
where
import Source.Parser.Base
import Control.Monad
import Data.Maybe
import DDC.Type
import DDC.Var
import qualified Source.Token					as K
import qualified Shared.VarPrim					as Var
import qualified Text.ParserCombinators.Parsec.Combinator	as Parsec
import qualified Text.ParserCombinators.Parsec.Prim		as Parsec


-- Super -------------------------------------------------------------------------------------------
pSuper :: Parser Super
pSuper
 = 	do	pTok K.Plus
		return SProp

 <|>	-- KIND -> SUPER
	do	k1	<- pKind1
                pTok K.RightArrow
		s2	<- pSuper
		return $ SFun k1 s2
		
 <?>    "pSuper"	


-- Kind --------------------------------------------------------------------------------------------
pKind :: Parser Kind
pKind
 = 	-- KIND -> KIND
	do	k1	<- pKind1

	        Parsec.option k1
                 $ do	pTok K.RightArrow
			k2	<- pKind
			return $ KFun k1 k2

 <?>    "pKind"

pKind1 :: Parser Kind
pKind1
 = 	do	pTok K.Star
 		return	kValue

 <|>	do	pTok K.Percent
 		return	kRegion

 <|>	do	pTok K.Bang
 		return	kEffect

 <|>	do	pTok K.Dollar
 		return	kClosure

 <|>	-- ( KIND )
	pRParen pKind

 <?>    "pKind1"


-- Type --------------------------------------------------------------------------------------------

-- Parse a type.
pType :: Parser Type
pType
 =  	-- forall VAR .. . TYPE
 	do	tok	<- pTok K.Forall
		vks	<- Parsec.many1 pVar_withKind
		pTok K.Dot
		body	<- pType_bodyFetters
		return	$ makeTForall_back vks body

 <|>	pType_bodyFetters
 <?>    "pType"

-- Parse a quantified variable, with optional kind
pVar_withKind :: Parser (Var, Kind)
pVar_withKind
 = 	pRParen pVar_withKind1
 <|>	pVar_withKind1
 <?>    "pVar_withKind"

pVar_withKind1 :: Parser (Var, Kind)
pVar_withKind1
 =	do	var	<- liftM (vNameDefaultN NameType) pVarPlain
		(	do	-- VAR :: KIND
				pTok K.HasType
				kind	<- pKind
				return	(var, kind)

		 <|>	-- VAR
			return (var, kindOfVarSpace (varNameSpace var)))

 <?>    "pVar_withKind1"

-- Parse a body type with an optional context and constraint list
pType_bodyFetters :: Parser Type
pType_bodyFetters
 = do	mContext	<- Parsec.optionMaybe
				(Parsec.try pType_someContext)

  	body		<- pType_body

 	mFetters	<- Parsec.optionMaybe
                	(do	pTok K.HasConstraint
				Parsec.sepBy1 pFetter (pTok K.Comma))

	case concat $ maybeToList mContext ++ maybeToList mFetters of
		[]	-> return body
		fs	-> return $ TFetters body fs

pType_someContext :: Parser [Fetter]
pType_someContext
 = do	fs <- pType_hsContext
	pTok K.RightArrowEquals
        return fs

 <|>	pType_context []


-- Parse some class constraints written as a Disciple context
--	C1 => C2 => C3 ...
pType_context :: [Fetter] -> Parser [Fetter]
pType_context accum
 =	-- CONTEXT => CONTEXT ..
	do	fs	<- pType_classConstraint
 		pTok K.RightArrowEquals
		pType_context (fs : accum)

 <|>	return accum

-- Parser some class constraints written as a Haskell context
--	(ClassConstraint ,ClassConstraint*)
pType_hsContext :: Parser [Fetter]
pType_hsContext
 = 	-- (CONTEXT, ..)
	pRParen $ Parsec.sepBy1 pType_classConstraint (pTok K.Comma)

-- Parse a single type class constraint
--	Con Type*
pType_classConstraint :: Parser Fetter
pType_classConstraint
 =	do	con	<- pOfSpace NameClass pCon
	 	ts	<- Parsec.many1 pType_body1
		return	$ FConstraint con ts



-- Parse a body type (without a forall or fetters)
pType_body :: Parser Type
pType_body
 = 	-- TYPE -> TYPE
	-- TYPE -(EFF/CLO)> TYPE
	-- TYPE -(EFF)> TYPE
	-- TYPE -(CLO)> TYPE
	do	t1	<- pType_body3

		mRest	<- Parsec.optionMaybe
			(	-- TYPE -> TYPE
				do	pTok K.RightArrow
					t2	<- pType_body
					return	(tPure, tEmpty, t2)

				-- TYPE -(EFF/CLO)> TYPE
			  <|>	do	pTok K.Dash
					pTok K.RBra
					pTypeDashRBra t1)

		case mRest of
			Just (eff, clo, t2)	-> return $ makeTFun t1 t2 eff clo
			_			-> return t1


pTypeDashRBra :: Type -> Parser (Type, Type, Type)
pTypeDashRBra t1
 =	-- EFF/CLO)> TYPE
	-- EFF)> TYPE
	do	eff	<- pEffect
		clo	<- Parsec.option tEmpty pClosure
		pTok K.RKet
		pTok K.AKet
		t2	<- pType_body
		return	(eff, clo, t2)

  <|>	-- CLO)> TYPE
	do	clo	<- pClosure
		pTok K.RKet
		pTok K.AKet
		t2	<- pType_body
		return (tPure, clo, t2)


pType_body3 :: Parser Type
pType_body3
 = pType_body2 >>= \t ->

	-- TYPE {read}
 	(do	tElab	<- pCParen
		    $	(do	pVarPlainNamed "read"
				return tElaborateRead)

		    <|>	(do	pVarPlainNamed "write"
				return tElaborateWrite)

		    <|>	(do	pVarPlainNamed "modify"
				return tElaborateModify)

		return	$ TApp tElab t)

	-- TYPE
   <|>		return	t
   <?>      "pType_body3"

-- | Parse a type that can be used as an argument to a function constructor
pType_body2 :: Parser Type
pType_body2
 =	-- CON TYPE..
	do	t1	<- pTyCon
 		args	<- Parsec.many pType_body1
		return	$ makeTApp t1 args
		
 <|>	do	t1	<- pType_body1
		Parsec.option t1
			(do	ts	<- Parsec.many1 pType_body1
				return	$ makeTApp t1 ts)

 <?>    "pType_body2"

-- | Parse a type that can be used as an argument to a type constructor
pType_body1 :: Parser Type
pType_body1
 = 	-- ()
 	do	pTok K.Unit
		return	$ makeTData Var.primTUnit kValue []

 <|>	-- [ TYPE , .. ]
 	do	ts	<- pSParen $ Parsec.sepBy1 pType_body (pTok K.Comma)
		return	$ makeTData 
				Var.primTList
				(KFun (KFun kRegion kValue) kValue)
				ts

 	-- VAR
 	-- If a variable had no namespace qualifier out the front the lexer will leave
	--	it in NameNothing. In this case we know its actually a type variable, so can
	--	set it in NameType.
 <|>	do	var	<- liftM (vNameDefaultN NameType) $ pQualified pVarPlain
		return	$ TVar 	(let Just k = kindOfSpace $ varNameSpace var in k) $ UVar var
		
 <|>	pRParen pParenTypeBody

 <|>	-- \*Bot / %Bot / !Bot / \$Bot
	pConBottom

 <|>	-- CON
 	do	con	<- pTyCon
		return	$ con

 <?>    "pType_body1"


pConBottom :: Parser Type
pConBottom
 =	do	pTok	K.Star
		pCParen $ return []
		return	$ tBot kValue

 <|>	do	pTok	K.Percent
		pCParen $ return []
        	return $ tBot kRegion

 <|>	do	pTok	K.Bang
		pCParen $ return []
        	return $ tBot kEffect

 <|>	do	pTok	K.Dollar
		pCParen $ return []
        	return $ tBot kClosure


pTyCon :: Parser Type
pTyCon 	
 = do	con	<- pQualified pCon
	case varNameSpace con of
		NameEffect 	-> pTyCon_effect con
		_		-> return $ TCon (TyConData con kValue)
		
pTyCon_effect con
 = case varName con of
	"Read"		-> return tRead
	"ReadH"		-> return tHeadRead
	"ReadT"		-> return tDeepRead
	"Write"		-> return tWrite
	"WriteT"	-> return tDeepWrite
	_		-> return $ TCon (TyConEffect (TyConEffectTop con) kEffect)


pParenTypeBody :: Parser Type
pParenTypeBody
 =	-- (VAR :: KIND)
	Parsec.try
	  (do	var	<- pOfSpace NameType pVarPlain
		pTok K.HasType
		kind	<- pKind

		return	$ TVar kind $ UVar var)

 <|>	-- (CON :: KIND)
	Parsec.try
	  (do	con	<- pOfSpace NameType $ pQualified pCon
		pTok K.HasType
		kind	<- pKind

		return	$ makeTData con kind [])

 <|>	-- ( TYPE, TYPE .. )
	-- ( TYPE )
	do	ts	<- Parsec.sepBy1 pType_body (pTok K.Comma)
		case ts of
                  [hts] -> return hts
                  _ -> return	$ makeTData 
				(Var.primTTuple (length ts))
				(KFun (KFun kRegion kValue) kValue)
				ts


-- Effect ------------------------------------------------------------------------------------------
-- | Parse an effect
pEffect :: Parser Type
pEffect
 = 	-- VAR
 	do	var	<- pVarPlainOfSpace [NameEffect]
		return $ TVar kEffect $ UVar var

 <|>	-- !{ EFF; .. }
 	do	pTok	K.Bang
		effs	<- pCParen $ Parsec.sepEndBy1 pEffect pSemis
		return	$ TSum kEffect effs

 <|>	-- !CON TYPE..
	do	t1	<- pTyCon
 		ts	<- Parsec.many pType_body1
		return	$ makeTApp t1 ts

 <?>    "pEfect"


-- Closure -----------------------------------------------------------------------------------------
-- | Parse a closure
pClosure :: Parser Type
pClosure
  	-- VAR :  CLO
  	-- VAR :  TYPE
	-- VAR $> VAR
 =	Parsec.try 
	  (do	var	<- pQualified pVar
	 
	 	do	pTok K.Colon
			let varN	= vNameDefaultN NameValue var
			-- VAR :  CLO
			do	clo	<- pClosure
				return $ makeTFree varN clo

		  	-- VAR :  TYPE
		   	 <|> do	typ	<- pType
 				return	$ makeTFree varN typ

		-- VAR $> CLO
	  	 <|> do	pTok K.HoldsMono
			var2	<- pVarPlain
			let varN	= vNameDefaultN NameType var
	 		let var2N	= vNameDefaultN NameType var2
			return	$ makeTDanger
					(TVar kRegion $ UVar varN)
					(TVar (let Just k = kindOfSpace $ varNameSpace var2N in k) $ UVar var2N))


 <|>	-- \${ CLO ; .. }
 	do	pTok	K.Dollar
		clos	<- pCParen $ Parsec.sepEndBy1 pClosure pSemis
		return	$ TSum kClosure clos

 <|>	-- VAR
	do	var	<- pVarPlainOfSpace [NameClosure]
		return	$ TVar kClosure $ UVar var
 <?>    "pClosure"


-- Fetter ------------------------------------------------------------------------------------------
-- | Parse a fetter
pFetter :: Parser Fetter
pFetter
 =  	-- CON TYPE..
	do	con	<- pOfSpace NameClass $ pQualified pCon
		ts	<- Parsec.many pType_body1
		return	$ FConstraint con ts


 <|>	-- VAR =  EFFECT/CLOSURE
	-- VAR :> EFFECT/CLOSURE
	(pVarPlainOfSpace [NameEffect, NameClosure] >>= \var ->
		-- VAR = EFFECT/CLOSURE
 		(do	pTok K.Equals
			effClo	<- pEffect <|> pClosure
			return	$ FWhere (TVar (let Just k = kindOfSpace $ varNameSpace var in k) $ UVar var)
					 effClo)

		-- VAR :> EFFECT/CLOSURE
	  <|>	(do	pTok K.IsSuptypeOf
			effClo	<- pEffect <|> pClosure
			return	$ FMore (TVar (let Just k = kindOfSpace $ varNameSpace var in k) $ UVar var)
					effClo))
 <?>    "pFetter"

-- TypeOp ------------------------------------------------------------------------------------------

-- Parse an operational type
pTypeOp :: Parser Type
pTypeOp
 =	do	t1	<- pTypeOp1
		Parsec.option t1
                	(do	pTok K.RightArrow
				t2	<- pTypeOp
				return	$ makeTFun t1 t2 tPure tEmpty)

 <?>    "pTypeOp"

pTypeOp1 :: Parser Type
pTypeOp1
 =	-- CON
	do	con	<- pOfSpace NameType $ pQualified pCon
		ts	<- Parsec.many pTypeOp1
		return	$ makeTData con KNil ts

