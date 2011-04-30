{-# OPTIONS -fno-warn-type-defaults #-}

module Llvm.Runtime.Tags
	( tagBase
	, tagBasePlus
	, tagData
	, tagDataR
	, tagSuspIndir
	, tagDataRS
	, tagIndir
	, tagSusp
	, tagFixedThunk

	, objModeDataRS
	, objFixedDataR
	, objFixedDataM
	)
where

import Data.Bits

import Llvm
import Llvm.Util

-- See tagging stuff in:
--	runtime/Object.h
--	runtime/Alloc.ci
--	runtime/Prim/Boxing.ci


-- Tag values from runtime/Object.h.

tagBase :: LlvmVar
tagBase = i32LitVar 0


-- tagBasePlus value is tagBase + x
tagBasePlus :: Int -> LlvmVar
tagBasePlus x = i32LitVar x

tagData :: Int -> LlvmVar
tagData tag = i32LitVar (objFixedData + tag * 256)

tagDataR :: LlvmVar
tagDataR = i32LitVar 0x31

tagSuspIndir :: LlvmVar
tagSuspIndir = i32LitVar 0x51

tagDataRS :: Int -> LlvmVar
tagDataRS dataSize = i32LitVar ((shiftL dataSize 4) .|. objModeDataRS)

tagIndir :: LlvmVar
tagIndir = i32LitVar 0x0fffffd

tagSusp :: LlvmVar
tagSusp = i32LitVar 0x0fffffe

tagFixedThunk :: LlvmVar
tagFixedThunk = i32LitVar  ((0x0ffffff * 256) + 0x11)

-- objModeForward, objModeFixed
objModeDataRS :: Int
--objModeForward	= 0x00
--objModeFixed	= 0x01
objModeDataRS	= 0x03

objFixedData :: Int
objFixedData	= 0x21

objFixedDataR :: Int
objFixedDataR = 0x31

objFixedDataM :: Int
objFixedDataM = 0x41


