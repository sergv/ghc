%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
%************************************************************************
%*									*
\section[BinderInfo]{Information attached to binders by SubstAnal}
%*									*
%************************************************************************

\begin{code}
#include "HsVersions.h"

module BinderInfo (
	BinderInfo(..),
	FunOrArg, DuplicationDanger, InsideSCC,  -- NB: all abstract (yay!)

	inlineUnconditionally, okToInline,

	addBinderInfo, orBinderInfo, 

	argOccurrence, funOccurrence, dangerousArgOcc, noBinderInfo,
	markMany, markDangerousToDup, markInsideSCC,
	getBinderInfoArity,
	setBinderInfoArityToZero,

	isFun, isDupDanger -- for Simon Marlow deforestation
    ) where

IMP_Ubiq(){-uitous-}

import CoreUnfold	( FormSummary(..) )
import Pretty
import Util		( panic )
\end{code}

The @BinderInfo@ describes how a variable is used in a given scope.

NOTE: With SCCs we have to be careful what we unfold! We don't want to
change the attribution of execution costs. If we decide to unfold
within an SCC we can tag the definition as @DontKeepBinder@.
Definitions tagged as @KeepBinder@ are discarded when we enter the
scope of an SCC.

\begin{code}
data BinderInfo
  = DeadCode	-- Dead code; discard the binding.

  | ManyOcc	-- Everything else besides DeadCode and OneOccs

	Int	-- number of arguments on stack when called; this is a minimum guarantee


  | OneOcc	-- Just one occurrence (or one each in
		-- mutually-exclusive case alts).

      FunOrArg	-- How it occurs

      DuplicationDanger

      InsideSCC

      Int	-- Number of mutually-exclusive case alternatives
		-- in which it occurs

		-- Note that we only worry about the case-alt counts
		-- if the OneOcc is substitutable -- that's the only
		-- time we *use* the info; we could be more clever for
		-- other cases if we really had to. (WDP/PS)

      Int	-- number of arguments on stack when called; minimum guarantee

-- In general, we are feel free to substitute unless
-- (a) is in an argument position (ArgOcc)
-- (b) is inside a lambda [or type lambda?] (DupDanger)
-- (c) is inside an SCC expression (InsideSCC)
-- (d) is in the RHS of a binding for a variable with an INLINE pragma
--	(because the RHS will be inlined regardless of its size)
--	[again, DupDanger]

data FunOrArg
  = FunOcc 	-- An occurrence in a function position
  | ArgOcc	-- Other arg occurrence

    -- When combining branches of a case, only report FunOcc if
    -- both branches are FunOccs

data DuplicationDanger
  = DupDanger	-- Inside a non-linear lambda (that is, a lambda which
		-- is sure to be instantiated only once), or inside
		-- the rhs of an INLINE-pragma'd thing.  Either way,
		-- substituting a redex for this occurrence is
		-- dangerous because it might duplicate work.

  | NoDupDanger	-- It's ok; substitution won't duplicate work.

data InsideSCC
  = InsideSCC	    -- Inside an SCC; so be careful when substituting.
  | NotInsideSCC    -- It's ok.

noBinderInfo = ManyOcc 0	-- A non-committal value
\end{code}


Predicates
~~~~~~~~~~

\begin{code}
okToInline
	:: FormSummary	-- What the thing to be inlined is like
	-> BinderInfo 	-- How the thing to be inlined occurs
	-> Bool		-- True => it's small enough to inline
	-> Bool		-- True => yes, inline it

-- Always inline bottoms
okToInline BottomForm occ_info small_enough
  = True	-- Unless one of the type args is unboxed??
		-- This used to be checked for, but I can't
		-- see why so I've left it out.

-- Non-WHNFs can be inlined if they occur once, or are small
okToInline OtherForm (OneOcc _ _ _ n_alts _) small_enough | n_alts <= 1 = True
okToInline OtherForm any_occ 		     small_enough 		= small_enough

-- A WHNF can be inlined if it doesn't occur inside a lambda,
-- and occurs exactly once or 
--     occurs once in each branch of a case and is small
okToInline form (OneOcc _ NoDupDanger _ n_alts _) small_enough 
  = is_whnf_form form && 
    (n_alts <= 1 || small_enough)
  where
    is_whnf_form VarForm   = True
    is_whnf_form ValueForm = True
    is_whnf_form other     = False

okToInline form any_occ small_enough = False
\end{code}

@inlineUnconditionally@ decides whether a let-bound thing can
definitely be inlined.

\begin{code}
inlineUnconditionally :: Bool -> BinderInfo -> Bool

--inlineUnconditionally ok_to_dup DeadCode = True
inlineUnconditionally ok_to_dup (OneOcc FunOcc NoDupDanger NotInsideSCC n_alt_occs _)
  = n_alt_occs <= 1 || ok_to_dup
	    -- We [i.e., Patrick] don't mind the code explosion,
	    -- though.  We could have a flag to limit the
	    -- damage, e.g., limit to M alternatives.

inlineUnconditionally _ _ = False
\end{code}

\begin{code}
isFun :: FunOrArg -> Bool
isFun FunOcc = True
isFun _ = False

isDupDanger :: DuplicationDanger -> Bool
isDupDanger DupDanger = True
isDupDanger _ = False
\end{code}


Construction
~~~~~~~~~~~~~
\begin{code}
argOccurrence, funOccurrence :: Int -> BinderInfo

funOccurrence = OneOcc FunOcc NoDupDanger NotInsideSCC 1
argOccurrence = OneOcc ArgOcc NoDupDanger NotInsideSCC 1

markMany, markDangerousToDup, markInsideSCC :: BinderInfo -> BinderInfo

markMany (OneOcc _ _ _ _ ar) = ManyOcc ar
markMany (ManyOcc ar) 	     = ManyOcc ar
markMany DeadCode	     = panic "markMany"

markDangerousToDup (OneOcc posn _ in_scc n_alts ar)
  = OneOcc posn DupDanger in_scc n_alts ar
markDangerousToDup other = other

dangerousArgOcc = OneOcc ArgOcc DupDanger NotInsideSCC 1 0

markInsideSCC (OneOcc posn dup_danger _ n_alts ar)
  = OneOcc posn dup_danger InsideSCC n_alts ar
markInsideSCC other = other

addBinderInfo, orBinderInfo
	:: BinderInfo -> BinderInfo -> BinderInfo

addBinderInfo DeadCode info2 = info2
addBinderInfo info1 DeadCode = info1
addBinderInfo info1 info2
	= ManyOcc (min (getBinderInfoArity info1) (getBinderInfoArity info2))

-- (orBinderInfo orig new) is used in two situations:
-- First, it combines occurrence info from branches of a case
--
-- Second, when a variable whose occurrence
--   info is currently "orig" is bound to a variable whose occurrence info is "new"
--	eg  (\new -> e) orig
--   What we want to do is to *worsen* orig's info to take account of new's

orBinderInfo DeadCode info2 = info2
orBinderInfo info1 DeadCode = info1
orBinderInfo (OneOcc posn1 dup1 scc1 n_alts1 ar_1)
		      (OneOcc posn2 dup2 scc2 n_alts2 ar_2)
  = OneOcc (combine_posns posn1 posn2)
	   (combine_dups  dup1  dup2)
	   (combine_sccs  scc1  scc2)
	   (n_alts1 + n_alts2)
	   (min ar_1 ar_2)
  where
    combine_dups DupDanger _ = DupDanger	-- Too paranoid?? ToDo
    combine_dups _ DupDanger = DupDanger
    combine_dups _ _	     = NoDupDanger

    combine_sccs InsideSCC _ = InsideSCC	-- Too paranoid?? ToDo
    combine_sccs _ InsideSCC = InsideSCC
    combine_sccs _ _	     = NotInsideSCC

orBinderInfo info1 info2
	= ManyOcc (min (getBinderInfoArity info1) (getBinderInfoArity info2))

combine_posns FunOcc FunOcc = FunOcc -- see comment at FunOrArg defn
combine_posns _  	 _  = ArgOcc

{-
multiplyBinderInfo orig@(ManyOcc _) new
  = ManyOcc (min (getBinderInfoArity orig) (getBinderInfoArity new))

multiplyBinderInfo orig new@(ManyOcc _)
  = ManyOcc (min (getBinderInfoArity orig) (getBinderInfoArity new))

multiplyBinderInfo (OneOcc posn1 dup1 scc1 n_alts1 ar_1)
		   (OneOcc posn2 dup2 scc2 n_alts2 ar_2)  
  = OneOcc (combine_posns posn1 posn2) ???
-}

setBinderInfoArityToZero :: BinderInfo -> BinderInfo
setBinderInfoArityToZero DeadCode    = DeadCode
setBinderInfoArityToZero (ManyOcc _) = ManyOcc 0
setBinderInfoArityToZero (OneOcc fa dd sc i _) = OneOcc fa dd sc i 0
\end{code}

\begin{code}
getBinderInfoArity (DeadCode) = 0
getBinderInfoArity (ManyOcc i) = i
getBinderInfoArity (OneOcc _ _ _ _ i) = i
\end{code}

\begin{code}
instance Outputable BinderInfo where
  ppr sty DeadCode     = ppStr "Dead"
  ppr sty (ManyOcc ar) = ppBesides [ ppStr "Many-", ppInt ar ]
  ppr sty (OneOcc posn dup_danger in_scc n_alts ar)
    = ppBesides [ ppStr "One-", pp_posn posn, ppChar '-', pp_danger dup_danger,
		  ppChar '-', pp_scc in_scc,  ppChar '-', ppInt n_alts,
		  ppChar '-', ppInt ar ]
    where
      pp_posn FunOcc = ppStr "fun"
      pp_posn ArgOcc = ppStr "arg"

      pp_danger DupDanger   = ppStr "*dup*"
      pp_danger NoDupDanger = ppStr "nodup"

      pp_scc InsideSCC	  = ppStr "*SCC*"
      pp_scc NotInsideSCC = ppStr "noscc"
\end{code}

