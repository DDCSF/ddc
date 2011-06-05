
-- | Use data type declarations to make code for each of the data constructors.
module Sea.Ctor
	(expandCtorTree)
where
import Util
import DDC.Sea.Exp
import DDC.Var
import Shared.VarUtil		(VarGenM, newVarN)
import qualified Shared.Unique	as Unique
import qualified Data.Map	as Map

type	ExM	= VarGenM


-- | Expand the definitions of data constructors in this tree.
expandCtorTree :: Tree () -> Tree ()
expandCtorTree tree
	= evalState (liftM concat $ mapM expandDataP tree)
	$ VarId Unique.seaCtor 0


-- | Expand data constructors in a top level thing.
expandDataP :: Top ()	-> ExM [Top ()]
expandDataP p
 = case p of
 	PData v ctors
	 -> liftM concat
	  $ mapM (\(v, ctor) -> expandCtor ctor)
	  $ Map.toList ctors

	_		-> return [p]


-- | Expand the definition of a constructor.
expandCtor
	:: CtorDef
	-> ExM [Top ()]

expandCtor (CtorDef vCtor tCtor arity tag fields)
 = do	-- var of the constructed object.
	nObj		<- liftM NAuto $ newVarN NameValue

	-- allocate the object
	let allocS 	= SAssign (XVar nObj tPtrObj) tPtrObj
			$ XPrim (MAlloc (PAllocData vCtor arity)) []

	-- Initialise all the fields.
	(stmtss, mArgVs)
		<- liftM unzip $ mapM (expandField nObj) [0 .. arity - 1]

	let fieldSs	= concat stmtss
	let argVs	= catMaybes mArgVs

	-- Return the result.
	let retS	= SReturn $ (XVar nObj tPtrObj)

	let stmts	= [allocS] ++ fieldSs ++ [retS]
	let super	= [PSuper vCtor argVs tPtrObj stmts]

	return 		$ super


-- | Create initialization code for this field
expandField
	:: Name				-- ^ name of the object being constructed.
	-> Int				-- ^ index of argument.
	-> ExM 	( [Stmt ()]		-- initialization code
		, Maybe (Var, Type))	-- the arguments to the constructor
					--	(will be Nothing if the field is secondary)
expandField nObj ixArg
 = do	vArg	<- newVarN NameValue
	return	( [SAssign 	(XArgBoxedData (XVar nObj tPtrObj) ixArg)
				tPtrObj
				(XVar (NAuto vArg) tPtrObj)]
		, Just (vArg, tPtrObj) )

