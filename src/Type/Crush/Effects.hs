-- | Crush effects into their parts.

module Type.Crush.Effects
	( crushEffectC )
where

import Util

import qualified Data.Set	as Set
import Data.Set			(Set)

import qualified Data.Map	as Map
import Data.Map			(Map)

import qualified Shared.Var	as Var
import qualified Shared.VarBind	as Var
import Shared.VarPrim
import Shared.Var		(VarBind, NameSpace(..))
import Shared.Error

import Type.Exp
import Type.Util
import Type.State
import Type.Class
import Type.Feed
import Type.Trace
import Type.Pretty
import Type.Util.Pack

import Type.Check.GraphicalData
import Type.Crush.Unify

import Type.Plate.Collect	(collectClassIds)
import Type.Plate.Trans

-----
debug	= True
trace s	= when debug $ traceM s
stage	= "Type.Crush.Effect"

-- Try and crush the effect in this node.
crushEffectC :: ClassId -> SquidM ()
crushEffectC cid
 = do	
	trace	$ "*   crushEffectC " 	% cid			% "\n"

	-- trace out the effect
	eTrace		<- liftM (sortFsT . eraseFConstraints) $ traceType cid
 	trace	$ "    eTrace      = "  %> prettyTS eTrace	% "\n"

	-- check for loops in the data.
	--	this should never happen, but check anyway so that we don't end up in an infinite loop
	--	during packEffect.
	let cidsDataLoop	= checkGraphicalDataT eTrace
	trace	$ "    cidsDataLoop     = " % cidsDataLoop % "\n\n"

	when (not $ isNil cidsDataLoop)
	 $ panic stage 	$ "crushEffectC: found loops through data portion of type\n"
		 	% "    eTrace = " %> prettyTS eTrace	% "\n"

	-- pack the effect into normal form
	let ePacked	= packEffect eTrace
	trace	$ "    ePacked     = " 	% ePacked		% "\n"

	-- crush out some ctors.
	eCrushed	<- transformTM crushEffectT ePacked
	trace	$ "    eCrushed    = "	% eCrushed 	% "\n"
	
	if eCrushed /= ePacked
	 then do	
		-- update the class queue with the new effect
		Just c	<- lookupClass cid
	 	updateClass cid
			c { classType = Just eCrushed }
			
		-- For the classIds in the new effect, update the backrefs to point
		--	to this class.
		let classIds	= collectClassIds eCrushed
		mapM_ (\cid' -> addBackRef cid' cid) classIds

		-- update the register
		mapM_ (\e -> unregisterClass e cid)
			$ catMaybes
			$ map (\t -> case t of 
					TEffect ve _ 	
					 -> Just $ Var.bind ve

					TFetters fs (TEffect ve _)
					 -> Just $ Var.bind ve

					TVar{}		-> Nothing 
					TClass{}	-> Nothing
					_ -> panic stage 
						$ "crushEffectC: can't crush weird looking effect\n"
						% "   t       = " % t			% "\n\n"
						% "   eTrace  = " % prettyTS eTrace	% "\n\n"
						% "   ePacked = " % ePacked		% "\n\n")
						
							
			$ flattenTSum ePacked

		registerNodeT cid eCrushed
		return ()

	 else	return ()

eraseFConstraints tt
 = case tt of
 	TFetters fs t	
	 -> let eraseF (FConstraint{})	= True
	 	eraseF (FProj{})	= True
		eraseF _		= False
	    in  addFetters (filter (not . eraseF) fs) t

	_		-> tt


-- Try and crush this effect into parts.
crushEffectT :: Effect -> SquidM Effect
crushEffectT tt

	-- Read of outer constructor of object.
	| TEffect ve [t1]	<- tt
	, Var.bind ve == Var.EReadH
	= do	case t1 of
		 TData v (tR : ts)	-> return $ TEffect primRead [tR]
		 TData v []		-> return $ TBot KEffect
		 _			-> return $ tt
	


	-- Read of whole object. (deep read).
	| TEffect ve [t1]	<- tt
	, Var.bind ve == Var.EReadT
	= do	
		let (rs, ds)	= slurpVarsRD t1
		let esRegion	= map (\r -> TEffect primRead  [r])  rs
		let esType	= map (\d -> TEffect primReadT [d]) ds

	  	return	$ makeTSum KEffect 
			$ (esRegion ++ esType)


	-- Write of whole object. (deep write)
	| TEffect ve [t1]	<- tt
	, Var.bind ve == Var.EWriteT
	= do	
		let (rs, ds)	= slurpVarsRD t1
		let esRegion	= map (\r -> TEffect primWrite  [r])   rs
		let esType	= map (\d -> TEffect primWriteT [d]) ds
				
	  	return	$ makeTSum KEffect 
			$ (esRegion ++ esType)


	-- can't crush this one
	| otherwise
	= return $ tt


-- | Load in the effect for this cid.
loadEffect :: ClassId -> SquidM Type
loadEffect cid
 = do	Just c		<- lookupClass cid
 	let Just tNode	= classType c

	tPacked		<- liftM packType $ loadType tNode

	let es		= map (\e -> case e of
				TEffect v ts	-> TEffect v (map (fst . stripFettersT) ts)
				_		-> e)
			$ flattenTSum tPacked

	return		$ makeTSum KEffect es


-- | Load in nodes for every cid in this type.
loadType :: Type -> SquidM Type
loadType tt	= transformTM loadType' tt

loadType' tt
 = case tt of
 	TClass k cid	-> liftM packType $ traceType cid
	_ 		-> return tt
	
	 


