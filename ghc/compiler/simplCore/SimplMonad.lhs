%
% (c) The AQUA Project, Glasgow University, 1993-1996
%
\section[SimplMonad]{The simplifier Monad}

\begin{code}
#include "HsVersions.h"

module SimplMonad (
	SYN_IE(SmplM),
	initSmpl, returnSmpl, thenSmpl, thenSmpl_,
	mapSmpl, mapAndUnzipSmpl,

	-- Counting
	SimplCount{-abstract-}, TickType(..), tick, tickN,
	simplCount, detailedSimplCount,
	zeroSimplCount, showSimplCount, combineSimplCounts,

	-- Cloning
	cloneId, cloneIds, cloneTyVarSmpl, newIds, newId
    ) where

IMP_Ubiq(){-uitous-}
IMPORT_1_3(Ix)

IMPORT_DELOOPER(SmplLoop)		-- well, cheating sort of

import Id		( mkSysLocal, mkIdWithNewUniq )
import CoreUnfold	( SimpleUnfolding )
import SimplEnv
import SrcLoc		( mkUnknownSrcLoc )
import TyVar		( cloneTyVar )
import UniqSupply	( getUnique, getUniques, splitUniqSupply,
			  UniqSupply
			)
import Util		( zipWithEqual, panic )

infixr 9  `thenSmpl`, `thenSmpl_`
\end{code}

%************************************************************************
%*									*
\subsection{Monad plumbing}
%*									*
%************************************************************************

For the simplifier monad, we want to {\em thread} a unique supply and a counter.
(Command-line switches move around through the explicitly-passed SimplEnv.)

\begin{code}
type SmplM result
  = UniqSupply
  -> SimplCount    -- things being threaded
  -> (result, SimplCount)
\end{code}

\begin{code}
initSmpl :: UniqSupply -- no init count; set to 0
	  -> SmplM a
	  -> (a, SimplCount)

initSmpl us m = m us zeroSimplCount

{-# INLINE thenSmpl #-}
{-# INLINE thenSmpl_ #-}
{-# INLINE returnSmpl #-}

returnSmpl :: a -> SmplM a
returnSmpl e us sc = (e, sc)

thenSmpl  :: SmplM a -> (a -> SmplM b) -> SmplM b
thenSmpl_ :: SmplM a -> SmplM b -> SmplM b

thenSmpl m k us sc0
  = case splitUniqSupply us of { (s1, s2) ->
    case (m s1 sc0)	    of { (m_result, sc1) ->
    k m_result s2 sc1 }}

thenSmpl_ m k us sc0
  = case splitUniqSupply us of { (s1, s2) ->
    case (m s1 sc0) 	    of { (_, sc1) ->
    k s2 sc1 }}

mapSmpl	    	:: (a -> SmplM b) -> [a] -> SmplM [b]
mapAndUnzipSmpl :: (a -> SmplM (b, c)) -> [a] -> SmplM ([b],[c])

mapSmpl f [] = returnSmpl []
mapSmpl f (x:xs)
  = f x		    `thenSmpl` \ x'  ->
    mapSmpl f xs    `thenSmpl` \ xs' ->
    returnSmpl (x':xs')

mapAndUnzipSmpl f [] = returnSmpl ([],[])
mapAndUnzipSmpl f (x:xs)
  = f x			    `thenSmpl` \ (r1,  r2)  ->
    mapAndUnzipSmpl f xs    `thenSmpl` \ (rs1, rs2) ->
    returnSmpl (r1:rs1, r2:rs2)
\end{code}


%************************************************************************
%*									*
\subsection{Counting up what we've done}
%*									*
%************************************************************************

The assoc list isn't particularly costly, because we only use
the number of ticks in ``real life.''

The right thing to do, if you want that to go fast, is thread
a mutable array through @SimplM@.

\begin{code}
data SimplCount
  = SimplCount	FAST_INT	    -- number of ticks
		[(TickType, Int)]   -- assoc list of all diff kinds of ticks

data TickType
  = UnfoldingDone    | MagicUnfold	| ConReused
  | CaseFloatFromLet | CaseOfCase
  | LetFloatFromLet  | LetFloatFromCase
  | KnownBranch	     | Let2Case
  | CaseMerge	     | CaseElim
  | CaseIdentity
  | AtomicRhs	-- Rhs of a let-expression was an atom
  | EtaExpansion
  | CaseOfError
  | TyBetaReduction
  | BetaReduction
  | SpecialisationDone
  {- BEGIN F/B ENTRIES -}
  -- the 8 rules
  | FoldrBuild	     	-- foldr f z (build g) ==>
  | FoldrAugment	-- foldr f z (augment g z) ==>
  | Foldr_Nil		-- foldr f z [] ==>
  | Foldr_List		-- foldr f z (x:...) ==>

  | FoldlBuild	        -- foldl f z (build g) ==>
  | FoldlAugment	-- foldl f z (augment g z) ==>
  | Foldl_Nil		-- foldl f z [] ==>
  | Foldl_List		-- foldl f z (x:...) ==>

  | Foldr_Cons_Nil	-- foldr (:) [] => id
  | Foldr_Cons		-- foldr (:) => flip (++)

  | Str_FoldrStr	-- foldr f z "hello" => unpackFoldrPS__ f z "hello"
  | Str_UnpackCons	-- unpackFoldrPS# (:) z "hello" => unpackAppendPS__ z "hello"
  | Str_UnpackNil	-- unpackAppendPS__ [] "hello" => "hello"
  {- END F/B ENTRIES -}
  deriving (Eq, Ord, Ix)

instance Text TickType where
    showsPrec p UnfoldingDone	= showString "UnfoldingDone    "
    showsPrec p MagicUnfold	= showString "MagicUnfold      "
    showsPrec p ConReused	= showString "ConReused        "
    showsPrec p CaseFloatFromLet= showString "CaseFloatFromLet "
    showsPrec p CaseOfCase	= showString "CaseOfCase       "
    showsPrec p LetFloatFromLet	= showString "LetFloatFromLet  "
    showsPrec p LetFloatFromCase= showString "LetFloatFromCase "
    showsPrec p KnownBranch	= showString "KnownBranch      "
    showsPrec p Let2Case	= showString "Let2Case         "
    showsPrec p CaseMerge	= showString "CaseMerge        "
    showsPrec p CaseElim	= showString "CaseElim         "
    showsPrec p CaseIdentity	= showString "CaseIdentity     "
    showsPrec p AtomicRhs	= showString "AtomicRhs        "
    showsPrec p EtaExpansion	= showString "EtaExpansion     "
    showsPrec p CaseOfError	= showString "CaseOfError      "
    showsPrec p TyBetaReduction	= showString "TyBetaReduction  "
    showsPrec p BetaReduction	= showString "BetaReduction    "
    showsPrec p SpecialisationDone 
				= showString "Specialisation   "

	-- Foldr/Build Stuff:
    showsPrec p FoldrBuild	= showString "FoldrBuild       "
    showsPrec p FoldrAugment	= showString "FoldrAugment     "
    showsPrec p Foldr_Nil	= showString "Foldr_Nil        "
    showsPrec p Foldr_List	= showString "Foldr_List       "

    showsPrec p FoldlBuild	= showString "FoldlBuild       "
    showsPrec p FoldlAugment	= showString "FoldlAugment     "
    showsPrec p Foldl_Nil	= showString "Foldl_Nil        "
    showsPrec p Foldl_List	= showString "Foldl_List       "

    showsPrec p Foldr_Cons_Nil	= showString "Foldr_Cons_Nil   "
    showsPrec p Foldr_Cons	= showString "Foldr_Cons       "

    showsPrec p Str_FoldrStr	= showString "Str_FoldrStr     "
    showsPrec p Str_UnpackCons  = showString "Str_UnpackCons   "
    showsPrec p Str_UnpackNil   = showString "Str_UnpackNil    "

showSimplCount :: SimplCount -> String

showSimplCount (SimplCount _ stuff)
  = shw stuff
  where
    shw []	    = ""
    shw ((t,n):tns) | n /= 0	= show t ++ ('\t' : show n) ++ ('\n' : shw tns)
		    | otherwise = shw tns

zeroSimplCount :: SimplCount
zeroSimplCount
  = SimplCount ILIT(0)
      [ (UnfoldingDone, 0),
	(MagicUnfold, 0),
	(ConReused, 0),
	(CaseFloatFromLet, 0),
	(CaseOfCase, 0),
	(LetFloatFromLet, 0),
	(LetFloatFromCase, 0),
	(KnownBranch, 0),
	(Let2Case, 0),
	(CaseMerge, 0),
	(CaseElim, 0),
	(CaseIdentity, 0),
	(AtomicRhs, 0),
	(EtaExpansion, 0),
	(CaseOfError, 0),
	(TyBetaReduction,0),
	(BetaReduction,0),
	(SpecialisationDone,0),
	-- Foldr/Build Stuff:
	(FoldrBuild, 0),
	(FoldrAugment, 0),
	(Foldr_Nil, 0),
	(Foldr_List, 0),
	(FoldlBuild, 0),
	(FoldlAugment, 0),
	(Foldl_Nil, 0),
	(Foldl_List, 0),
	(Foldr_Cons_Nil, 0),
	(Foldr_Cons, 0),

	(Str_FoldrStr, 0),
	(Str_UnpackCons, 0),
	(Str_UnpackNil, 0) ]
--
--= array (con2tag_TickType UnfoldingDone, con2tag_TickType FoldrInline)
--        [ i := 0 | i <- indices zeroSimplCount ]
\end{code}

Counting-related monad functions:
\begin{code}
tick :: TickType -> SmplM ()

tick tick_type us (SimplCount n stuff)
  = ((), SimplCount (n _ADD_ ILIT(1))
#ifdef OMIT_SIMPL_COUNTS
		    stuff -- don't change anything
#else
		    (inc_tick stuff)
#endif
    )
  where
    inc_tick [] = panic "couldn't inc_tick!"
    inc_tick (x@(ttype, cnt) : xs)
      = if ttype == tick_type then
	    let
		incd = cnt + 1
	    in
	    (ttype, incd) : xs
	else
	    x : inc_tick xs

tickN :: TickType -> Int -> SmplM ()

tickN tick_type 0 us counts 
  = ((), counts)
tickN tick_type IBOX(increment) us (SimplCount n stuff)
  = ((), SimplCount (n _ADD_ increment)
#ifdef OMIT_SIMPL_COUNTS
		    stuff -- don't change anything
#else
		    (inc_tick stuff)
#endif
    )
  where
    inc_tick [] = panic "couldn't inc_tick!"
    inc_tick (x@(ttype, cnt) : xs)
      = if ttype == tick_type then
	    let
		incd = cnt + IBOX(increment)
	    in
	    (ttype, incd) : xs
	else
	    x : inc_tick xs

simplCount :: SmplM Int
simplCount us sc@(SimplCount n _) = (IBOX(n), sc)

detailedSimplCount :: SmplM SimplCount
detailedSimplCount us sc = (sc, sc)

combineSimplCounts :: SimplCount -> SimplCount -> SimplCount

#ifdef OMIT_SIMPL_COUNTS
combineSimplCounts (SimplCount n1 stuff1) (SimplCount n2 stuff2)
  = SimplCount (n1 _ADD_ n2)
	       stuff1 -- just pick one
#else
combineSimplCounts (SimplCount n1 stuff1) (SimplCount n2 stuff2)
  = SimplCount (n1 _ADD_ n2)
	       (zipWithEqual "combineSimplCounts" (\ (t1,c1) (t2,c2) -> (t1,c1+c2)) stuff1 stuff2)
#endif
\end{code}

%************************************************************************
%*									*
\subsection{Monad primitives}
%*									*
%************************************************************************

\begin{code}
newId :: Type -> SmplM Id
newId ty us sc
  = (mkSysLocal SLIT("s") uniq ty mkUnknownSrcLoc, sc)
  where
    uniq = getUnique us

newIds :: [Type] -> SmplM [Id]
newIds tys us sc
  = (zipWithEqual "newIds" mk_id tys uniqs, sc)
  where
    uniqs  = getUniques (length tys) us
    mk_id ty uniq = mkSysLocal SLIT("s") uniq ty mkUnknownSrcLoc

cloneTyVarSmpl :: TyVar -> SmplM TyVar

cloneTyVarSmpl tyvar us sc
  = (new_tyvar, sc)
  where
   uniq = getUnique us
   new_tyvar = cloneTyVar tyvar uniq

cloneId :: SimplEnv -> InBinder -> SmplM OutId
cloneId env (id,_) us sc
  = (mkIdWithNewUniq id_with_new_ty uniq, sc)
  where
    id_with_new_ty = simplTyInId env id
    uniq = getUnique us

cloneIds :: SimplEnv -> [InBinder] -> SmplM [OutId]
cloneIds env binders = mapSmpl (cloneId env) binders
\end{code}
