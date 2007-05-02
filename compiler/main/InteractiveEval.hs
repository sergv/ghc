-- -----------------------------------------------------------------------------
--
-- (c) The University of Glasgow, 2005-2007
--
-- Running statements interactively
--
-- -----------------------------------------------------------------------------

module InteractiveEval (
#ifdef GHCI
        RunResult(..), Status(..), Resume(..),
	runStmt, stepStmt, -- traceStmt,
        resume,  stepResume, -- traceResume,
        abandon, abandonAll,
        getResumeContext,
	setContext, getContext,	
        nameSetToGlobalRdrEnv,
	getNamesInScope,
	getRdrNamesInScope,
	moduleIsInterpreted,
	getInfo,
	exprType,
	typeKind,
	parseName,
	showModule,
        isModuleInterpreted,
	compileExpr, dynCompileExpr,
	lookupName,
        obtainTerm, obtainTerm1
#endif
        ) where

#ifdef GHCI

#include "HsVersions.h"

import HscMain          hiding (compileExpr)
import HscTypes
import TcRnDriver
import Type             hiding (typeKind)
import TcType           hiding (typeKind)
import InstEnv
import Var              hiding (setIdType)
import Id
import IdInfo
import Name             hiding ( varName )
import NameSet
import RdrName
import VarSet
import VarEnv
import ByteCodeInstr
import Linker
import DynFlags
import Unique
import Module
import Panic
import UniqFM
import Maybes
import Util
import SrcLoc
import RtClosureInspect
import Packages
import BasicTypes
import Outputable

import Data.Dynamic
import Control.Monad
import Foreign
import GHC.Exts
import Data.Array
import Control.Exception as Exception
import Control.Concurrent
import Data.IORef
import Foreign.StablePtr

-- -----------------------------------------------------------------------------
-- running a statement interactively

data RunResult
  = RunOk [Name] 		-- ^ names bound by this evaluation
  | RunFailed	 		-- ^ statement failed compilation
  | RunException Exception	-- ^ statement raised an exception
  | RunBreak ThreadId [Name] BreakInfo

data Status
   = Break HValue BreakInfo ThreadId
          -- ^ the computation hit a breakpoint
   | Complete (Either Exception [HValue])
          -- ^ the computation completed with either an exception or a value

data Resume
   = Resume {
       resumeStmt      :: String,       -- the original statement
       resumeThreadId  :: ThreadId,     -- thread running the computation
       resumeBreakMVar :: MVar (),   
       resumeStatMVar  :: MVar Status,
       resumeBindings  :: ([Id], TyVarSet),
       resumeFinalIds  :: [Id],         -- [Id] to bind on completion
       resumeApStack   :: HValue,       -- The object from which we can get
                                        -- value of the free variables.
       resumeBreakInfo :: BreakInfo,    -- the breakpoint we stopped at.
       resumeSpan      :: SrcSpan       -- just a cache, otherwise it's a pain
                                        -- to fetch the ModDetails & ModBreaks
                                        -- to get this.
   }

getResumeContext :: Session -> IO [Resume]
getResumeContext s = withSession s (return . ic_resume . hsc_IC)

data SingleStep
   = RunToCompletion
   | SingleStep
   | RunAndLogSteps

isStep RunToCompletion = False
isStep _ = True

-- type History = [HistoryItem]
-- 
-- data HistoryItem = HistoryItem HValue BreakInfo
-- 
-- historyBreakInfo :: HistoryItem -> BreakInfo
-- historyBreakInfo (HistoryItem _ bi) = bi
-- 
-- setContextToHistoryItem :: Session -> HistoryItem -> IO ()
-- setContextToHistoryItem

-- We need to track two InteractiveContexts:
--      - the IC before runStmt, which is restored on each resume
--      - the IC binding the results of the original statement, which
--        will be the IC when runStmt returns with RunOk.

-- | Run a statement in the current interactive context.  Statement
-- may bind multple values.
runStmt :: Session -> String -> IO RunResult
runStmt session expr = runStmt_ session expr RunToCompletion

-- | Run a statement, stopping at the first breakpoint location encountered
-- (regardless of whether the breakpoint is enabled).
stepStmt :: Session -> String -> IO RunResult
stepStmt session expr = runStmt_ session expr SingleStep

-- | Run a statement, logging breakpoints passed, and stopping when either
-- an enabled breakpoint is reached, or the statement completes.
-- traceStmt :: Session -> String -> IO (RunResult, History)
-- traceStmt session expr = runStmt_ session expr RunAndLogSteps

runStmt_ (Session ref) expr step
   = do 
	hsc_env <- readIORef ref

        breakMVar  <- newEmptyMVar  -- wait on this when we hit a breakpoint
        statusMVar <- newEmptyMVar  -- wait on this when a computation is running 

	-- Turn off -fwarn-unused-bindings when running a statement, to hide
	-- warnings about the implicit bindings we introduce.
	let dflags'  = dopt_unset (hsc_dflags hsc_env) Opt_WarnUnusedBinds
	    hsc_env' = hsc_env{ hsc_dflags = dflags' }

        maybe_stuff <- hscStmt hsc_env' expr

        case maybe_stuff of
	   Nothing -> return RunFailed
	   Just (ids, hval) -> do

              when (isStep step) $ setStepFlag

              -- set the onBreakAction to be performed when we hit a
              -- breakpoint this is visible in the Byte Code
              -- Interpreter, thus it is a global variable,
              -- implemented with stable pointers
              withBreakAction breakMVar statusMVar $ do

              let thing_to_run = unsafeCoerce# hval :: IO [HValue]
              status <- sandboxIO statusMVar thing_to_run

              let ic = hsc_IC hsc_env
                  bindings = (ic_tmp_ids ic, ic_tyvars ic)
              handleRunStatus expr ref bindings ids breakMVar statusMVar status

handleRunStatus expr ref bindings final_ids breakMVar statusMVar status =
   case status of  
      -- did we hit a breakpoint or did we complete?
      (Break apStack info tid) -> do
        hsc_env <- readIORef ref
        let 
            mod_name    = moduleName (breakInfo_module info)
            mod_details = fmap hm_details (lookupUFM (hsc_HPT hsc_env) mod_name)
            breaks      = md_modBreaks (expectJust "handlRunStatus" mod_details)
        --
        (hsc_env1, names, span) <- bindLocalsAtBreakpoint hsc_env 
                                        apStack info breaks
        let
            resume = Resume expr tid breakMVar statusMVar 
                              bindings final_ids apStack info span
            hsc_env2 = pushResume hsc_env1 resume
        --
        writeIORef ref hsc_env2
        return (RunBreak tid names info)
      (Complete either_hvals) ->
	case either_hvals of
	    Left e -> return (RunException e)
	    Right hvals -> do
                hsc_env <- readIORef ref
                let final_ic = extendInteractiveContext (hsc_IC hsc_env)
                                        final_ids emptyVarSet
                        -- the bound Ids never have any free TyVars
                    final_names = map idName final_ids
                writeIORef ref hsc_env{hsc_IC=final_ic}
                Linker.extendLinkEnv (zip final_names hvals)
                return (RunOk final_names)

{-
traceRunStatus ref final_ids  
               breakMVar statusMVar status history = do
  hsc_env <- readIORef ref
  case status of
     -- when tracing, if we hit a breakpoint that is not explicitly
     -- enabled, then we just log the event in the history and continue.
     (Break apStack info tid) | not (isBreakEnabled hsc_env info) -> do
        let history' = consBL (apStack,info) history
        withBreakAction breakMVar statusMVar $ do
           status <- withInterruptsSentTo
                (do putMVar breakMVar ()  -- this awakens the stopped thread...
                    return tid)
                (takeMVar statusMVar)     -- and wait for the result

           traceRunStatus ref final_ids 
                          breakMVar statusMVar status history'
     _other ->
        handleRunStatus ref final_ids 
                        breakMVar statusMVar status
                  
-}        

foreign import ccall "rts_setStepFlag" setStepFlag :: IO () 

-- this points to the IO action that is executed when a breakpoint is hit
foreign import ccall "&breakPointIOAction" 
        breakPointIOAction :: Ptr (StablePtr (BreakInfo -> HValue -> IO ())) 

-- When running a computation, we redirect ^C exceptions to the running
-- thread.  ToDo: we might want a way to continue even if the target
-- thread doesn't die when it receives the exception... "this thread
-- is not responding".
sandboxIO :: MVar Status -> IO [HValue] -> IO Status
sandboxIO statusMVar thing = 
  withInterruptsSentTo 
        (forkIO (do res <- Exception.try thing
                    putMVar statusMVar (Complete res)))
        (takeMVar statusMVar)

withInterruptsSentTo :: IO ThreadId -> IO r -> IO r
withInterruptsSentTo io get_result = do
  ts <- takeMVar interruptTargetThread
  child <- io
  putMVar interruptTargetThread (child:ts)
  get_result `finally` modifyMVar_ interruptTargetThread (return.tail)

withBreakAction breakMVar statusMVar io
 = bracket setBreakAction resetBreakAction (\_ -> io)
 where
   setBreakAction = do
     stablePtr <- newStablePtr onBreak
     poke breakPointIOAction stablePtr
     return stablePtr

   onBreak info apStack = do
     tid <- myThreadId
     putMVar statusMVar (Break apStack info tid)
     takeMVar breakMVar

   resetBreakAction stablePtr = do
     poke breakPointIOAction noBreakStablePtr
     freeStablePtr stablePtr

noBreakStablePtr = unsafePerformIO $ newStablePtr noBreakAction
noBreakAction info apStack = putStrLn "*** Ignoring breakpoint"

resume :: Session -> IO RunResult
resume session = resume_ session RunToCompletion

stepResume :: Session -> IO RunResult
stepResume session = resume_ session SingleStep

-- traceResume :: Session -> IO RunResult
-- traceResume session handle = resume_ session handle RunAndLogSteps

resume_ :: Session -> SingleStep -> IO RunResult
resume_ (Session ref) step
 = do
   hsc_env <- readIORef ref
   let ic = hsc_IC hsc_env
       resume = ic_resume ic

   case resume of
     [] -> throwDyn (ProgramError "not stopped at a breakpoint")
     (r:rs) -> do
        -- unbind the temporary locals by restoring the TypeEnv from
        -- before the breakpoint, and drop this Resume from the
        -- InteractiveContext.
        let (resume_tmp_ids, resume_tyvars) = resumeBindings r
            ic' = ic { ic_tmp_ids  = resume_tmp_ids,
                       ic_tyvars   = resume_tyvars,
                       ic_resume   = rs }
        writeIORef ref hsc_env{ hsc_IC = ic' }
        
        -- remove any bindings created since the breakpoint from the 
        -- linker's environment
        let new_names = map idName (filter (`notElem` resume_tmp_ids)
                                           (ic_tmp_ids ic))
        Linker.deleteFromLinkEnv new_names
        

        when (isStep step) $ setStepFlag
        case r of 
          Resume expr tid breakMVar statusMVar bindings 
              final_ids apStack info _ -> do
                withBreakAction breakMVar statusMVar $ do
                status <- withInterruptsSentTo
                             (do putMVar breakMVar ()
                                      -- this awakens the stopped thread...
                                 return tid)
                             (takeMVar statusMVar)
                                      -- and wait for the result
                handleRunStatus expr ref bindings final_ids 
                                breakMVar statusMVar status

-- -----------------------------------------------------------------------------
-- After stopping at a breakpoint, add free variables to the environment

bindLocalsAtBreakpoint
        :: HscEnv
        -> HValue
        -> BreakInfo
        -> ModBreaks
        -> IO (HscEnv, [Name], SrcSpan)
bindLocalsAtBreakpoint hsc_env apStack info breaks = do

   let 
       index     = breakInfo_number info
       vars      = breakInfo_vars info
       result_ty = breakInfo_resty info
       occs      = modBreaks_vars breaks ! index
       span      = modBreaks_locs breaks ! index

   -- filter out any unboxed ids; we can't bind these at the prompt
   let pointers = filter (\(id,_) -> isPointer id) vars
       isPointer id | PtrRep <- idPrimRep id = True
                    | otherwise              = False

   let (ids, offsets) = unzip pointers
   hValues <- mapM (getIdValFromApStack apStack) offsets
   new_ids <- zipWithM mkNewId occs ids
   let names = map idName ids

   -- make an Id for _result.  We use the Unique of the FastString "_result";
   -- we don't care about uniqueness here, because there will only be one
   -- _result in scope at any time.
   let result_fs = FSLIT("_result")
       result_name = mkInternalName (getUnique result_fs)
                          (mkVarOccFS result_fs) (srcSpanStart span)
       result_id   = Id.mkLocalId result_name result_ty

   -- for each Id we're about to bind in the local envt:
   --    - skolemise the type variables in its type, so they can't
   --      be randomly unified with other types.  These type variables
   --      can only be resolved by type reconstruction in RtClosureInspect
   --    - tidy the type variables
   --    - globalise the Id (Ids are supposed to be Global, apparently).
   --
   let all_ids | isPointer result_id = result_id : ids
               | otherwise           = ids
       (id_tys, tyvarss) = mapAndUnzip (skolemiseTy.idType) all_ids
       (_,tidy_tys) = tidyOpenTypes emptyTidyEnv id_tys
       new_tyvars = unionVarSets tyvarss             
       new_ids = zipWith setIdType all_ids tidy_tys
       global_ids = map (globaliseId VanillaGlobal) new_ids

   let   ictxt0 = hsc_IC hsc_env
         ictxt1 = extendInteractiveContext ictxt0 global_ids new_tyvars

   Linker.extendLinkEnv (zip names hValues)
   Linker.extendLinkEnv [(result_name, unsafeCoerce# apStack)]
   return (hsc_env{ hsc_IC = ictxt1 }, result_name:names, span)
  where
   mkNewId :: OccName -> Id -> IO Id
   mkNewId occ id = do
     let uniq = idUnique id
         loc = nameSrcLoc (idName id)
         name = mkInternalName uniq occ loc
         ty = tidyTopType (idType id)
         new_id = Id.mkGlobalId VanillaGlobal name ty (idInfo id)
     return new_id

skolemiseTy :: Type -> (Type, TyVarSet)
skolemiseTy ty = (substTy subst ty, mkVarSet new_tyvars)
  where env           = mkVarEnv (zip tyvars new_tyvar_tys)
        subst         = mkTvSubst emptyInScopeSet env
        tyvars        = varSetElems (tyVarsOfType ty)
        new_tyvars    = map skolemiseTyVar tyvars
        new_tyvar_tys = map mkTyVarTy new_tyvars

skolemiseTyVar :: TyVar -> TyVar
skolemiseTyVar tyvar = mkTcTyVar (tyVarName tyvar) (tyVarKind tyvar) 
                                 (SkolemTv RuntimeUnkSkol)

-- Todo: turn this into a primop, and provide special version(s) for
-- unboxed things
foreign import ccall unsafe "rts_getApStackVal" 
        getApStackVal :: StablePtr a -> Int -> IO (StablePtr b)

getIdValFromApStack :: a -> Int -> IO HValue
getIdValFromApStack apStack stackDepth = do
     apSptr <- newStablePtr apStack
     resultSptr <- getApStackVal apSptr (stackDepth - 1)
     result <- deRefStablePtr resultSptr
     freeStablePtr apSptr
     freeStablePtr resultSptr 
     return (unsafeCoerce# result)

pushResume :: HscEnv -> Resume -> HscEnv
pushResume hsc_env resume = hsc_env { hsc_IC = ictxt1 }
  where
        ictxt0 = hsc_IC hsc_env
        ictxt1 = ictxt0 { ic_resume = resume : ic_resume ictxt0 }

-- -----------------------------------------------------------------------------
-- Abandoning a resume context

abandon :: Session -> IO Bool
abandon (Session ref) = do
   hsc_env <- readIORef ref
   let ic = hsc_IC hsc_env
       resume = ic_resume ic
   case resume of
      []    -> return False
      _:rs  -> do
         writeIORef ref hsc_env{ hsc_IC = ic { ic_resume = rs } }
         return True

abandonAll :: Session -> IO Bool
abandonAll (Session ref) = do
   hsc_env <- readIORef ref
   let ic = hsc_IC hsc_env
       resume = ic_resume ic
   case resume of
      []    -> return False
      _:rs  -> do
         writeIORef ref hsc_env{ hsc_IC = ic { ic_resume = [] } }
         return True

-- -----------------------------------------------------------------------------
-- Bounded list, optimised for repeated cons

data BoundedList a = BL
                        {-# UNPACK #-} !Int  -- length
                        {-# UNPACK #-} !Int  -- bound
                        [a] -- left
                        [a] -- right,  list is (left ++ reverse right)

consBL a (BL len bound left right)
  | len < bound = BL (len+1) bound (a:left) right
  | null right  = BL len     bound [] $! tail (reverse left)
  | otherwise   = BL len     bound [] $! tail right

toListBL (BL _ _ left right) = left ++ reverse right

lenBL (BL len _ _ _) = len

-- -----------------------------------------------------------------------------
-- | Set the interactive evaluation context.
--
-- Setting the context doesn't throw away any bindings; the bindings
-- we've built up in the InteractiveContext simply move to the new
-- module.  They always shadow anything in scope in the current context.
setContext :: Session
	   -> [Module]	-- entire top level scope of these modules
	   -> [Module]	-- exports only of these modules
	   -> IO ()
setContext sess@(Session ref) toplev_mods export_mods = do 
  hsc_env <- readIORef ref
  let old_ic  = hsc_IC     hsc_env
      hpt     = hsc_HPT    hsc_env
  --
  export_env  <- mkExportEnv hsc_env export_mods
  toplev_envs <- mapM (mkTopLevEnv hpt) toplev_mods
  let all_env = foldr plusGlobalRdrEnv export_env toplev_envs
  writeIORef ref hsc_env{ hsc_IC = old_ic { ic_toplev_scope = toplev_mods,
					    ic_exports      = export_mods,
					    ic_rn_gbl_env   = all_env }}

-- Make a GlobalRdrEnv based on the exports of the modules only.
mkExportEnv :: HscEnv -> [Module] -> IO GlobalRdrEnv
mkExportEnv hsc_env mods = do
  stuff <- mapM (getModuleExports hsc_env) mods
  let 
	(_msgs, mb_name_sets) = unzip stuff
	gres = [ nameSetToGlobalRdrEnv (availsToNameSet avails) (moduleName mod)
  	       | (Just avails, mod) <- zip mb_name_sets mods ]
  --
  return $! foldr plusGlobalRdrEnv emptyGlobalRdrEnv gres

nameSetToGlobalRdrEnv :: NameSet -> ModuleName -> GlobalRdrEnv
nameSetToGlobalRdrEnv names mod =
  mkGlobalRdrEnv [ GRE  { gre_name = name, gre_prov = vanillaProv mod }
		 | name <- nameSetToList names ]

vanillaProv :: ModuleName -> Provenance
-- We're building a GlobalRdrEnv as if the user imported
-- all the specified modules into the global interactive module
vanillaProv mod_name = Imported [ImpSpec { is_decl = decl, is_item = ImpAll}]
  where
    decl = ImpDeclSpec { is_mod = mod_name, is_as = mod_name, 
			 is_qual = False, 
			 is_dloc = srcLocSpan interactiveSrcLoc }

mkTopLevEnv :: HomePackageTable -> Module -> IO GlobalRdrEnv
mkTopLevEnv hpt modl
  = case lookupUFM hpt (moduleName modl) of
      Nothing -> throwDyn (ProgramError ("mkTopLevEnv: not a home module " ++ 
                                                showSDoc (ppr modl)))
      Just details ->
	 case mi_globals (hm_iface details) of
		Nothing  -> 
		   throwDyn (ProgramError ("mkTopLevEnv: not interpreted " 
						++ showSDoc (ppr modl)))
		Just env -> return env

-- | Get the interactive evaluation context, consisting of a pair of the
-- set of modules from which we take the full top-level scope, and the set
-- of modules from which we take just the exports respectively.
getContext :: Session -> IO ([Module],[Module])
getContext s = withSession s (\HscEnv{ hsc_IC=ic } ->
				return (ic_toplev_scope ic, ic_exports ic))

-- | Returns 'True' if the specified module is interpreted, and hence has
-- its full top-level scope available.
moduleIsInterpreted :: Session -> Module -> IO Bool
moduleIsInterpreted s modl = withSession s $ \h ->
 if modulePackageId modl /= thisPackage (hsc_dflags h)
        then return False
        else case lookupUFM (hsc_HPT h) (moduleName modl) of
                Just details       -> return (isJust (mi_globals (hm_iface details)))
                _not_a_home_module -> return False

-- | Looks up an identifier in the current interactive context (for :info)
getInfo :: Session -> Name -> IO (Maybe (TyThing,Fixity,[Instance]))
getInfo s name = withSession s $ \hsc_env -> tcRnGetInfo hsc_env name

-- | Returns all names in scope in the current interactive context
getNamesInScope :: Session -> IO [Name]
getNamesInScope s = withSession s $ \hsc_env -> do
  return (map gre_name (globalRdrEnvElts (ic_rn_gbl_env (hsc_IC hsc_env))))

getRdrNamesInScope :: Session -> IO [RdrName]
getRdrNamesInScope  s = withSession s $ \hsc_env -> do
  let 
      ic = hsc_IC hsc_env
      gbl_rdrenv = ic_rn_gbl_env ic
      ids = ic_tmp_ids ic
      gbl_names = concat (map greToRdrNames (globalRdrEnvElts gbl_rdrenv))
      lcl_names = map (mkRdrUnqual.nameOccName.idName) ids
  --
  return (gbl_names ++ lcl_names)


-- ToDo: move to RdrName
greToRdrNames :: GlobalRdrElt -> [RdrName]
greToRdrNames GRE{ gre_name = name, gre_prov = prov }
  = case prov of
     LocalDef -> [unqual]
     Imported specs -> concat (map do_spec (map is_decl specs))
  where
    occ = nameOccName name
    unqual = Unqual occ
    do_spec decl_spec
	| is_qual decl_spec = [qual]
	| otherwise         = [unqual,qual]
	where qual = Qual (is_as decl_spec) occ

-- | Parses a string as an identifier, and returns the list of 'Name's that
-- the identifier can refer to in the current interactive context.
parseName :: Session -> String -> IO [Name]
parseName s str = withSession s $ \hsc_env -> do
   maybe_rdr_name <- hscParseIdentifier (hsc_dflags hsc_env) str
   case maybe_rdr_name of
	Nothing -> return []
	Just (L _ rdr_name) -> do
	    mb_names <- tcRnLookupRdrName hsc_env rdr_name
	    case mb_names of
		Nothing -> return []
		Just ns -> return ns
		-- ToDo: should return error messages

-- | Returns the 'TyThing' for a 'Name'.  The 'Name' may refer to any
-- entity known to GHC, including 'Name's defined using 'runStmt'.
lookupName :: Session -> Name -> IO (Maybe TyThing)
lookupName s name = withSession s $ \hsc_env -> tcRnLookupName hsc_env name

-- -----------------------------------------------------------------------------
-- Getting the type of an expression

-- | Get the type of an expression
exprType :: Session -> String -> IO (Maybe Type)
exprType s expr = withSession s $ \hsc_env -> do
   maybe_stuff <- hscTcExpr hsc_env expr
   case maybe_stuff of
	Nothing -> return Nothing
	Just ty -> return (Just tidy_ty)
 	     where 
		tidy_ty = tidyType emptyTidyEnv ty

-- -----------------------------------------------------------------------------
-- Getting the kind of a type

-- | Get the kind of a  type
typeKind  :: Session -> String -> IO (Maybe Kind)
typeKind s str = withSession s $ \hsc_env -> do
   maybe_stuff <- hscKcType hsc_env str
   case maybe_stuff of
	Nothing -> return Nothing
	Just kind -> return (Just kind)

-----------------------------------------------------------------------------
-- cmCompileExpr: compile an expression and deliver an HValue

compileExpr :: Session -> String -> IO (Maybe HValue)
compileExpr s expr = withSession s $ \hsc_env -> do
  maybe_stuff <- hscStmt hsc_env ("let __cmCompileExpr = "++expr)
  case maybe_stuff of
	Nothing -> return Nothing
	Just (ids, hval) -> do
			-- Run it!
		hvals <- (unsafeCoerce# hval) :: IO [HValue]

		case (ids,hvals) of
		  ([n],[hv]) -> return (Just hv)
		  _ 	     -> panic "compileExpr"

-- -----------------------------------------------------------------------------
-- Compile an expression into a dynamic

dynCompileExpr :: Session -> String -> IO (Maybe Dynamic)
dynCompileExpr ses expr = do
    (full,exports) <- getContext ses
    setContext ses full $
        (mkModule
            (stringToPackageId "base") (mkModuleName "Data.Dynamic")
        ):exports
    let stmt = "let __dynCompileExpr = Data.Dynamic.toDyn (" ++ expr ++ ")"
    res <- withSession ses (flip hscStmt stmt)
    setContext ses full exports
    case res of
        Nothing -> return Nothing
        Just (ids, hvals) -> do
            vals <- (unsafeCoerce# hvals :: IO [Dynamic])
            case (ids,vals) of
                (_:[], v:[])    -> return (Just v)
                _               -> panic "dynCompileExpr"

-----------------------------------------------------------------------------
-- show a module and it's source/object filenames

showModule :: Session -> ModSummary -> IO String
showModule s mod_summary = withSession s $                        \hsc_env -> 
                           isModuleInterpreted s mod_summary >>=  \interpreted -> 
                           return (showModMsg (hscTarget(hsc_dflags hsc_env)) interpreted mod_summary)

isModuleInterpreted :: Session -> ModSummary -> IO Bool
isModuleInterpreted s mod_summary = withSession s $ \hsc_env -> 
  case lookupUFM (hsc_HPT hsc_env) (ms_mod_name mod_summary) of
	Nothing	      -> panic "missing linkable"
	Just mod_info -> return (not obj_linkable)
		      where
			 obj_linkable = isObjectLinkable (expectJust "showModule" (hm_linkable mod_info))

obtainTerm1 :: Session -> Bool -> Maybe Type -> a -> IO Term
obtainTerm1 sess force mb_ty x = withSession sess $ \hsc_env -> cvObtainTerm hsc_env force mb_ty (unsafeCoerce# x)

obtainTerm :: Session -> Bool -> Id -> IO (Maybe Term)
obtainTerm sess force id = withSession sess $ \hsc_env -> do
              mb_v <- Linker.getHValue (varName id) 
              case mb_v of
                Just v  -> fmap Just$ cvObtainTerm hsc_env force (Just$ idType id) v
                Nothing -> return Nothing

#endif /* GHCI */
