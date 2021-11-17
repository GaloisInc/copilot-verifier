{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Copilot.Verifier where

import Control.Lens (view, (^.), to)
import Control.Monad (foldM, forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (execStateT, lift, StateT(..))
import qualified Data.Text as Text
import qualified Data.Map.Strict as Map
import Data.IORef (newIORef, modifyIORef, IORef)
import qualified Text.LLVM.AST as L
import Data.List (genericLength)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Vector as V
import qualified Data.BitVector.Sized as BV
import qualified Prettyprinter as PP
import System.Exit (exitFailure)
import System.FilePath ((</>))

import Copilot.Compile.C99 (CSettings(..), compileWith)
import Copilot.Core
import qualified Copilot.Core.Type as CT

import qualified Copilot.Theorem.What4 as CW4

import Data.Parameterized.Ctx (EmptyCtx)
import Data.Parameterized.Context (pattern Empty)
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.NatRepr (intValue, natValue, testEquality, knownNat, type (<=) )
import Data.Parameterized.Nonce (globalNonceGenerator)
import Data.Parameterized.Some (Some(..))
import Data.Parameterized.TraversableFC (toListFC)
import Data.Parameterized.TraversableFC.WithIndex (ifoldlMFC)
import qualified Data.Parameterized.Vector as PVec

import Lang.Crucible.Backend
  ( IsSymInterface, Goals(..), Assumptions, Assertion
  , pushAssumptionFrame, popUntilAssumptionFrame
  , getProofObligations, clearProofObligations
  , LabeledPred(..), addDurableProofObligation
  , addAssumption, CrucibleAssumption(..), ppAbortExecReason
  -- , ProofObligations, proofGoal, goalsToList, labeledPredMsg
  )
import Lang.Crucible.Backend.Simple (newSimpleBackend)
import Lang.Crucible.CFG.Core (AnyCFG(..), cfgArgTypes, cfgReturnType)
import Lang.Crucible.CFG.Common ( freshGlobalVar )
import Lang.Crucible.FunctionHandle (newHandleAllocator)
import Lang.Crucible.Simulator
  ( SimContext(..), ctxSymInterface, ExecResult(..), ExecState(..)
  , defaultAbortHandler, runOverrideSim, partialValue, gpValue
  , GlobalVar, executeCrucible, OverrideSim, regValue
  , readGlobal, writeGlobal, callCFG, emptyRegMap, RegEntry(..)
  , AbortedResult(..)
  )
import Lang.Crucible.Simulator.GlobalState ( insertGlobal )
import Lang.Crucible.Simulator.RegValue (RegValue, RegValue'(..))
import Lang.Crucible.Simulator.SimError (SimError(..), SimErrorReason(..)) -- ppSimError
import Lang.Crucible.Types
  ( TypeRepr(..), (:~:)(..), KnownRepr(..), BoolType )

import Lang.Crucible.LLVM (llvmGlobals, registerModuleFn, register_llvm_overrides)
import Lang.Crucible.LLVM.Bytes (bitsToBytes)
import Lang.Crucible.LLVM.DataLayout (DataLayout)
import Lang.Crucible.LLVM.Extension (LLVM, ArchWidth)
import Lang.Crucible.LLVM.Globals (initializeAllMemory, populateAllGlobals)
import Lang.Crucible.LLVM.Intrinsics
  ( IntrinsicsOptions, OverrideTemplate, basic_llvm_override, LLVMOverride(..) )

import Lang.Crucible.LLVM.MemType
  ( MemType(..), SymType(..)
  , i1, i8, i16, i32, i64
  , memTypeSize, memTypeAlign
  , mkStructInfo
  )
import Lang.Crucible.LLVM.MemModel
  ( mkMemVar, withPtrWidth, HasLLVMAnn, MemImpl, LLVMAnnMap
  , HasPtrWidth, doResolveGlobal, doLoad, doStore
  , MemOptions, StorageType, bitvectorType
  , ptrAdd, toStorableType, projectLLVM_bv
  , pattern LLVMPointerRepr, pattern PtrRepr, llvmPointer_bv
  , memRepr, Mem
  )
import Lang.Crucible.LLVM.Translation
  ( ModuleTranslation(..), translateModule, globalInitMap
  , transContext, llvmPtrWidth, llvmTypeCtx, llvmTypeAsRepr
  )
import Lang.Crucible.LLVM.TypeContext (TypeContext, llvmDataLayout)

import Crux (defaultOutputConfig)
import Crux.Config (cfgJoin, Config(..))
import Crux.Config.Load (fromFile, fromEnv)
import Crux.Config.Common (cruxOptions, CruxOptions(..), postprocessOptions, outputOptions )
import Crux.Goal (proveGoalsOffline, provedGoalsTree)
import Crux.Log
  ( cruxLogMessageToSayWhat, withCruxLogMessage, outputHandle
  , Logs, SupportsCruxLogMessage, logGoal
  )
import Crux.Types (SimCtxt, Crux, ProcessedGoals(..), ProofResult(..))

import Crux.LLVM.Config (llvmCruxConfig, LLVMOptions(..))
import Crux.LLVM.Compile (genBitCode)
import Crux.LLVM.Simulate (setupSimCtxt, parseLLVM, explainFailure)
import CruxLLVMMain
  ( CruxLLVMLogging, withCruxLLVMLogging
  , cruxLLVMLoggingToSayWhat, processLLVMOptions
  )

import What4.Config
  (extendConfig)
import What4.Interface
  ( Pred, bvLit, bvAdd, bvUrem, bvMul, bvIsNonzero, bvEq, isEq
  , getConfiguration, freshBoundedBV, predToBV
  , getCurrentProgramLoc, printSymExpr
  , truePred, falsePred, eqPred, andPred, backendPred
  )
import What4.Expr.Builder (FloatModeRepr(..), ExprBuilder, BoolExpr, startCaching)
import What4.InterpretedFloatingPoint
  ( FloatInfoRepr(..), IsInterpretedFloatExprBuilder(..)
  , SingleFloat, DoubleFloat
  )
import What4.ProgramLoc (ProgramLoc, mkProgramLoc, Position(..))
import What4.Solver.Adapter (SolverAdapter(..))
import What4.Solver.Z3 (z3Adapter)
import What4.Symbol (safeSymbol)

verify :: CSettings -> [String] -> String -> Spec -> IO ()
verify csettings0 properties prefix spec =
  do (cruxOpts, llvmOpts, csettings, csrc) <-
       do llvmcfg <- llvmCruxConfig
          let cfg = cfgJoin cruxOptions llvmcfg
          -- TODO, load from and actual configuration file?
          fileOpts <- fromFile "copilot-verifier" cfg Nothing
          (cruxOpts0, llvmOpts0) <- foldM fromEnv fileOpts (cfgEnv cfg)
          let odir0 = cSettingsOutputDirectory csettings0
          let odir = -- A bit grimy, but this corresponds to how crux-llvm sets
                     -- its output directory.
                     if odir0 == "."
                       then "results" </> prefix
                       else odir0
          let csettings = csettings0{ cSettingsOutputDirectory = odir }
          let csrc = odir </> prefix ++ ".c"
          let cruxOpts1 = cruxOpts0{ outDir = odir, bldDir = odir, inputFiles = [csrc] }
          ocfg <- defaultOutputConfig cruxLogMessageToSayWhat
          let ?outputConfig = ocfg (Just (outputOptions cruxOpts1))
          cruxOpts2 <- withCruxLogMessage (postprocessOptions cruxOpts1)
          (cruxOpts3, llvmOpts2) <- processLLVMOptions (cruxOpts2, llvmOpts0{ optLevel = 0 })
          return (cruxOpts3, llvmOpts2, csettings, csrc)

     compileWith csettings prefix spec
     putStrLn ("Generated " ++ show csrc)

     ocfg <- defaultOutputConfig cruxLLVMLoggingToSayWhat
     let ?outputConfig = ocfg (Just (outputOptions cruxOpts))
     bcFile <- withCruxLLVMLogging (genBitCode cruxOpts llvmOpts)
     putStrLn ("Compiled " ++ prefix ++ " into " ++ bcFile)

     verifyBitcode csettings properties spec cruxOpts llvmOpts bcFile

verifyBitcode ::
  Logs CruxLLVMLogging =>
  CSettings ->
  [String] ->
  Spec ->
  CruxOptions ->
  LLVMOptions ->
  FilePath ->
  IO ()
verifyBitcode csettings properties spec cruxOpts llvmOpts bcFile =
  do halloc <- newHandleAllocator
     sym <- newSimpleBackend FloatUninterpretedRepr globalNonceGenerator
     -- turn on hash-consing
     startCaching sym
     bbMapRef <- newIORef mempty
     let ?recordLLVMAnnotation = \an bb -> modifyIORef bbMapRef (Map.insert an bb)
     ocfg <- defaultOutputConfig cruxLLVMLoggingToSayWhat
     let ?outputConfig = ocfg (Just (outputOptions cruxOpts))

     let adapters = [z3Adapter] -- TODO? configurable
     extendConfig (solver_adapter_config_options z3Adapter) (getConfiguration sym)

     memVar <- mkMemVar "llvm_memory" halloc

     let simctx = (setupSimCtxt halloc sym (memOpts llvmOpts) memVar)
                  { printHandle = view outputHandle ?outputConfig }

     llvmMod <- parseLLVM bcFile
     (Some trans, _warns) <-
        let ?transOpts = transOpts llvmOpts
         in translateModule halloc memVar llvmMod

     putStrLn ("Translated bitcode into Crucible")

     let llvmCtxt = trans ^. transContext
     let ?lc = llvmCtxt ^. llvmTypeCtx
     let ?memOpts = memOpts llvmOpts
     let ?intrinsicsOpts = intrinsicsOpts llvmOpts

     llvmPtrWidth llvmCtxt $ \ptrW ->
       withPtrWidth ptrW $
       withCruxLLVMLogging $
       do emptyMem   <- initializeAllMemory sym llvmCtxt llvmMod
          initialMem <- populateAllGlobals sym (globalInitMap trans) emptyMem

          putStrLn "Generating proof state data"
          proofStateBundle <- CW4.computeBisimulationProofBundle sym properties spec

          verifyInitialState cruxOpts adapters bbMapRef simctx initialMem
             (CW4.initialStreamState proofStateBundle)

          verifyStepBisimulation cruxOpts adapters csettings
             bbMapRef simctx llvmMod trans memVar emptyMem proofStateBundle

verifyInitialState ::
  IsSymInterface sym =>
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  sym ~ ExprBuilder t st fs =>
  HasPtrWidth wptr =>
  HasLLVMAnn sym =>
  (?memOpts :: MemOptions) =>
  (?lc :: TypeContext) =>

  CruxOptions ->
  [SolverAdapter st] ->
  IORef (LLVMAnnMap sym) ->
  SimCtxt Crux sym LLVM ->
  MemImpl sym ->
  CW4.BisimulationProofState sym ->
  IO ()
verifyInitialState cruxOpts adapters bbMapRef simctx mem initialState =
  do let sym = simctx^.ctxSymInterface
     putStrLn "Computing initial state verification conditions"
     frm <- pushAssumptionFrame sym

     assertStateRelation sym mem initialState

     popUntilAssumptionFrame sym frm

     putStrLn "Proving initial state verification conditions"
     proveObls cruxOpts adapters bbMapRef simctx

verifyStepBisimulation ::
  IsSymInterface sym =>
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  sym ~ ExprBuilder t st fs =>
  HasPtrWidth wptr =>
  HasLLVMAnn sym =>
  (1 <= ArchWidth arch) =>
  HasPtrWidth (ArchWidth arch) =>
  (?memOpts :: MemOptions) =>
  (?lc :: TypeContext) =>
  (?intrinsicsOpts :: IntrinsicsOptions) =>

  CruxOptions ->
  [SolverAdapter st] ->
  CSettings ->
  IORef (LLVMAnnMap sym) ->
  SimCtxt Crux sym LLVM ->
  L.Module ->
  ModuleTranslation arch ->
  GlobalVar Mem ->
  MemImpl sym ->
  CW4.BisimulationProofBundle sym ->
  IO ()
verifyStepBisimulation cruxOpts adapters csettings bbMapRef simctx llvmMod modTrans memVar mem prfbundle =
  do let sym = simctx^.ctxSymInterface
     putStrLn "Computing step bisimulation verification conditions"

     frm <- pushAssumptionFrame sym

     do -- set up the memory image
        mem' <- setupPrestate sym mem prfbundle

        -- sanity check, verify that we set up the memory in the expected relation
        assertStateRelation sym mem' (CW4.preStreamState prfbundle)

        -- set up trigger guard global variables
        let halloc = simHandleAllocator simctx
        let prepTrigger (nm, guard, _) =
              do gv <- freshGlobalVar halloc (Text.pack (nm ++ "_called")) BoolRepr
                 return (nm, gv, guard)
        triggerGlobals <- mapM prepTrigger (CW4.triggerState prfbundle)

        -- execute the step function
        let overrides = zipWith triggerOverride triggerGlobals (CW4.triggerState prfbundle)
        mem'' <- executeStep csettings simctx memVar mem' llvmMod modTrans triggerGlobals overrides (CW4.assumptions prfbundle)

        -- assert the poststate is in the relation
        assertStateRelation sym mem'' (CW4.postStreamState prfbundle)

     popUntilAssumptionFrame sym frm

     putStrLn "Proving step bisimulation verification conditions"
     proveObls cruxOpts adapters bbMapRef simctx


triggerOverride ::
  IsSymInterface sym =>
  (?memOpts :: MemOptions) =>
  (?lc :: TypeContext) =>
  (?intrinsicsOpts :: IntrinsicsOptions) =>
  (1 <= ArchWidth arch) =>
  HasPtrWidth (ArchWidth arch) =>
  HasLLVMAnn sym =>

  (Name, GlobalVar BoolType, Pred sym) ->
  (Name, BoolExpr t, [(Some Type, CW4.XExpr sym)]) ->
  OverrideTemplate (Crux sym) sym arch (RegEntry sym Mem) EmptyCtx Mem
triggerOverride (_,triggerGlobal,_) (nm, _guard, args) =
   let args' = map toTypeRepr args in
   case Ctx.fromList args' of
     Some argCtx ->
      basic_llvm_override $
      LLVMOverride decl argCtx UnitRepr $
        \memOps sym calledArgs ->
          do writeGlobal triggerGlobal (truePred sym)
             mem <- readGlobal memOps
             liftIO $ checkArgs sym mem (toListFC Some calledArgs) args
             return ()

 where
  decl = L.Declare
         { L.decLinkage = Nothing
         , L.decVisibility = Nothing
         , L.decRetType = L.PrimType L.Void
         , L.decName = L.Symbol nm
         , L.decArgs = map llvmArgTy args
         , L.decVarArgs = False
         , L.decAttrs = []
         , L.decComdat = Nothing
         }

  -- Use the `-CompositePtr` functions here to ensure that arguments with array
  -- or struct types are treated as pointers. See Note [Arrays and structs].
  toTypeRepr (Some ctp, _) = llvmTypeAsRepr (copilotTypeToMemTypeCompositePtr (llvmDataLayout ?lc) ctp) Some
  llvmArgTy (Some ctp, _) = copilotTypeToLLVMTypeCompositePtr ctp

  checkArgs sym mem = loop (0::Integer)
    where
    loop i (x:xs) ((ctp,v):vs) = checkArg sym mem i x ctp v >> loop (i+1) xs vs
    loop _ [] [] = return ()
    loop _ _ _ = fail $ "Argument list mismatch in " ++ nm

  checkArg sym mem i (Some (RegEntry tp v)) (Some ctp) x =
    do eq <- computeEqualVals sym mem ctp x tp v
       let shortmsg = "Trigger " ++ show nm ++ " argument " ++ show i
       let longmsg  = show (printSymExpr eq)
       let rsn      = AssertFailureSimError shortmsg longmsg
       loc <- getCurrentProgramLoc sym
       addDurableProofObligation sym (LabeledPred eq (SimError loc rsn))


executeStep :: forall sym arch.
  IsSymInterface sym =>
  (?memOpts :: MemOptions) =>
  (?lc :: TypeContext) =>
  (?intrinsicsOpts :: IntrinsicsOptions) =>
  (1 <= ArchWidth arch) =>
  HasPtrWidth (ArchWidth arch) =>
  HasLLVMAnn sym =>

  CSettings ->
  SimCtxt Crux sym LLVM ->
  GlobalVar Mem ->
  MemImpl sym ->
  L.Module ->
  ModuleTranslation arch ->
  [(Name, GlobalVar BoolType, Pred sym)] ->
  [OverrideTemplate (Crux sym) sym arch (RegEntry sym Mem) EmptyCtx Mem] ->
  [Pred sym] ->
  IO (MemImpl sym)
executeStep csettings simctx memVar mem llvmmod modTrans triggerGlobals triggerOverrides assums =
  do let initSt = InitialState simctx globSt defaultAbortHandler memRepr $
                    runOverrideSim memRepr runStep
     res <- executeCrucible [] initSt
     case res of
       FinishedResult _ pr -> return (pr^.partialValue.gpValue.to regValue)
       AbortedResult _ abortRes -> fail $ show $ ppAbortedResult abortRes
       TimeoutResult{} -> fail "simulation timed out!"
 where
  setupTrigger gs (_,gv,_) = insertGlobal gv (falsePred sym) gs
  globSt = foldl setupTrigger (llvmGlobals memVar mem) triggerGlobals
  llvm_ctx = modTrans ^. transContext
  stepName = cSettingsStepFunctionName csettings
  sym = simctx^.ctxSymInterface

  dummyLoc = mkProgramLoc "<>" InternalPos

  assumeProperty b =
    addAssumption sym (GenericAssumption dummyLoc "Property assumption" b)

  ppAbortedResult :: AbortedResult sym ext -> PP.Doc ann
  ppAbortedResult abortRes =
    case gatherReasons abortRes of
      reason :| [] -> reason
      reasons      -> PP.vcat $ "Simulation aborted for multiple reasons."
                              : NE.toList reasons

  gatherReasons :: AbortedResult sym ext -> NonEmpty (PP.Doc ann)
  gatherReasons (AbortedExec rsn _) =
    PP.vcat ["Simulation aborted!", ppAbortExecReason rsn] :| []
  gatherReasons (AbortedExit ec) =
    PP.vcat ["Simulation called exit!", PP.viaShow ec] :| []
  gatherReasons (AbortedBranch _ _ t f) =
    gatherReasons t <> gatherReasons f

  runStep :: OverrideSim (Crux sym) sym LLVM (RegEntry sym Mem) EmptyCtx Mem (MemImpl sym)
  runStep =
    do -- set up built-in functions
       register_llvm_overrides llvmmod [] triggerOverrides llvm_ctx
       -- set up functions defined in the module
       mapM_ (registerModuleFn llvm_ctx) (Map.elems (cfgMap modTrans))

       -- make any property assumptions
       liftIO (mapM_ assumeProperty assums)

       -- look up and run the step function
       () <- case Map.lookup (L.Symbol stepName) (cfgMap modTrans) of
         Just (_, AnyCFG anyCfg) ->
           case (cfgArgTypes anyCfg, cfgReturnType anyCfg) of
             (Empty, UnitRepr) -> regValue <$> callCFG anyCfg emptyRegMap
             _ -> fail $ unwords [show stepName, "should take no arguments and return void"]
         Nothing -> fail $ unwords ["Could not find step function named", show stepName]

       forM_ triggerGlobals $ \(nm, gv, guard) ->
         do guard' <- readGlobal gv
            eq <- liftIO $ eqPred sym guard guard'
            let shortmsg = "Trigger guard equality condition: " ++ show nm
            let longmsg  = show (printSymExpr eq)
            let rsn      = AssertFailureSimError shortmsg longmsg
            liftIO $ addDurableProofObligation sym (LabeledPred eq (SimError dummyLoc rsn))

       -- return the final state of the memory
       readGlobal memVar

setupPrestate ::
  IsSymInterface sym =>
  HasPtrWidth wptr =>
  HasLLVMAnn sym =>
  (?memOpts :: MemOptions) =>
  (?lc :: TypeContext) =>

  sym ->
  MemImpl sym ->
  CW4.BisimulationProofBundle sym ->
  IO (MemImpl sym)
setupPrestate sym mem0 prfbundle =
  do mem' <- foldM setupStreamState mem0 (CW4.streamState (CW4.preStreamState prfbundle))
     foldM setupExternalInput mem' (CW4.externalInputs prfbundle)

 where
   sizeTStorage :: StorageType
   sizeTStorage = bitvectorType (bitsToBytes (intValue ?ptrWidth))

   setupExternalInput mem (nm, Some ctp, v) =
     do -- Compute LLVM/Crucible type information from the Copilot type
        let memTy      = copilotTypeToMemTypeBool8 (llvmDataLayout ?lc) ctp
        let typeAlign  = memTypeAlign (llvmDataLayout ?lc) memTy
        stType <- toStorableType memTy
        Some typeRepr <- return (llvmTypeAsRepr memTy Some)

        -- resolve the global varible to a pointers
        ptrVal <- doResolveGlobal sym mem (L.Symbol nm)

        -- write the value into the global
        regVal <- copilotExprToRegValue sym v typeRepr
        doStore sym mem ptrVal typeRepr stType typeAlign regVal

   setupStreamState mem (nm, Some ctp, vs) =
     do -- TODO, should get these from somewhere inside copilot instead of building these names directly
        let idxName = "s" ++ show nm ++ "_idx"
        let bufName = "s" ++ show nm
        let buflen  = genericLength vs :: Integer

        -- Compute LLVM/Crucible type information from the Copilot type
        let memTy      = copilotTypeToMemTypeBool8 (llvmDataLayout ?lc) ctp
        let typeLen    = memTypeSize (llvmDataLayout ?lc) memTy
        let typeAlign  = memTypeAlign (llvmDataLayout ?lc) memTy
        stType <- toStorableType memTy
        Some typeRepr <- return (llvmTypeAsRepr memTy Some)

        -- Resolve the global names into base pointers
        idxPtr <- doResolveGlobal sym mem (L.Symbol idxName)
        bufPtr <- doResolveGlobal sym mem (L.Symbol bufName)

        -- Create a fresh index value in the proper range
        idxVal <- freshBoundedBV sym (safeSymbol idxName) ?ptrWidth
                     (Just 0) (Just (fromIntegral (buflen - 1)))
        idxVal' <- llvmPointer_bv sym idxVal

        -- store the index value in the correct location
        let sizeTAlign = memTypeAlign (llvmDataLayout ?lc) (IntType (natValue ?ptrWidth))
        mem' <- doStore sym mem idxPtr (LLVMPointerRepr ?ptrWidth) sizeTStorage sizeTAlign idxVal'

        buflen'  <- bvLit sym ?ptrWidth (BV.mkBV ?ptrWidth buflen)
        typeLen' <- bvLit sym ?ptrWidth (BV.mkBV ?ptrWidth (toInteger typeLen))

        flip execStateT mem' $
          forM_ (zip vs [0 ..]) $ \(v,i) ->
            do ptrVal <- lift $
                 do x1 <- bvAdd sym idxVal =<< bvLit sym ?ptrWidth (BV.mkBV ?ptrWidth i)
                    x2 <- bvUrem sym x1 buflen'
                    x3 <- bvMul sym x2 typeLen'
                    ptrAdd sym ?ptrWidth bufPtr x3

               regVal <- lift $ copilotExprToRegValue sym v typeRepr
               StateT $ \m ->
                 do m' <- doStore sym m ptrVal typeRepr stType typeAlign regVal
                    return ((),m')

assertStateRelation ::
  IsSymInterface sym =>
  HasPtrWidth wptr =>
  HasLLVMAnn sym =>
  (?memOpts :: MemOptions) =>
  (?lc :: TypeContext) =>

  sym ->
  MemImpl sym ->
  CW4.BisimulationProofState sym ->
  IO ()
assertStateRelation sym mem prfst =
  -- For each stream in the proof state, assert that the
  -- generated ring buffer global contains the corresponding
  -- values.
  forM_ (CW4.streamState prfst) assertStreamState

 where
   sizeTStorage :: StorageType
   sizeTStorage = bitvectorType (bitsToBytes (intValue ?ptrWidth))

   assertStreamState (nm, Some ctp, vs) =
     do -- TODO, should get these from somewhere inside copilot instead of building these names directly
        let idxName = "s" ++ show nm ++ "_idx"
        let bufName = "s" ++ show nm
        let buflen  = genericLength vs :: Integer

        -- Compute LLVM/Crucible type information from the Copilot type
        let memTy      = copilotTypeToMemTypeBool8 (llvmDataLayout ?lc) ctp
        let typeLen    = memTypeSize (llvmDataLayout ?lc) memTy
        let typeAlign  = memTypeAlign (llvmDataLayout ?lc) memTy
        stType <- toStorableType memTy
        Some typeRepr <- return (llvmTypeAsRepr memTy Some)

        -- Resolve the global names into base pointers
        idxPtr <- doResolveGlobal sym mem (L.Symbol idxName)
        bufPtr <- doResolveGlobal sym mem (L.Symbol bufName)

        -- read the value of the ring buffer index
        let sizeTAlign = memTypeAlign (llvmDataLayout ?lc) (IntType (natValue ?ptrWidth))
        idxVal <- projectLLVM_bv sym =<<
          doLoad sym mem idxPtr sizeTStorage (LLVMPointerRepr ?ptrWidth) sizeTAlign

        buflen'  <- bvLit sym ?ptrWidth (BV.mkBV ?ptrWidth buflen)
        typeLen' <- bvLit sym ?ptrWidth (BV.mkBV ?ptrWidth (toInteger typeLen))

        -- For each value in the stream description, read a corresponding value from
        -- memory and assert that they are equal.
        forM_ (zip vs [0 ..]) $ \(v,i) ->
          do ptrVal <-
               do x1 <- bvAdd sym idxVal =<< bvLit sym ?ptrWidth (BV.mkBV ?ptrWidth i)
                  x2 <- bvUrem sym x1 buflen'
                  x3 <- bvMul sym x2 typeLen'
                  ptrAdd sym ?ptrWidth bufPtr x3

             v' <- doLoad sym mem ptrVal stType typeRepr typeAlign
             eq <- computeEqualVals sym mem ctp v typeRepr v'
             let shortmsg = "State equality condition: " ++ show nm ++ " index value " ++ show i
             let longmsg  = show (printSymExpr eq)
             let rsn      = AssertFailureSimError shortmsg longmsg
             let loc      = mkProgramLoc "<>" InternalPos
             addDurableProofObligation sym (LabeledPred eq (SimError loc rsn))

        return ()

copilotExprToRegValue :: forall sym tp.
  IsSymInterface sym =>
  sym ->
  CW4.XExpr sym ->
  TypeRepr tp ->
  IO (RegValue sym tp)
copilotExprToRegValue sym = loop
  where
    loop :: forall tp'. CW4.XExpr sym -> TypeRepr tp' -> IO (RegValue sym tp')

    loop (CW4.XBool b) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @1) =
      llvmPointer_bv sym =<< predToBV sym b knownRepr
    loop (CW4.XBool b) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @8) =
      llvmPointer_bv sym =<< predToBV sym b knownRepr
    loop (CW4.XInt8 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @8) =
      llvmPointer_bv sym x
    loop (CW4.XInt16 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @16) =
      llvmPointer_bv sym x
    loop (CW4.XInt32 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @32) =
      llvmPointer_bv sym x
    loop (CW4.XInt64 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @64) =
      llvmPointer_bv sym x
    loop (CW4.XWord8 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @8) =
      llvmPointer_bv sym x
    loop (CW4.XWord16 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @16) =
      llvmPointer_bv sym x
    loop (CW4.XWord32 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @32) =
      llvmPointer_bv sym x
    loop (CW4.XWord64 x) (LLVMPointerRepr w) | Just Refl <- testEquality w (knownNat @64) =
      llvmPointer_bv sym x

    loop (CW4.XFloat x)  (FloatRepr SingleFloatRepr) = return x
    loop (CW4.XDouble x) (FloatRepr DoubleFloatRepr) = return x

    loop CW4.XEmptyArray (VectorRepr _tpr) =
      pure V.empty
    loop (CW4.XArray xs) (VectorRepr tpr) =
      V.generateM (PVec.lengthInt xs) (\i -> loop (PVec.elemAtUnsafe i xs) tpr)
    loop (CW4.XStruct xs) (StructRepr ctx) =
      Ctx.traverseWithIndex
        (\i tpr -> RV <$> loop (xs !! Ctx.indexVal i) tpr)
        ctx

    loop x tpr =
      fail $ unlines ["Mismatch between Copilot value and crucible value", show x, show tpr]


computeEqualVals :: forall sym tp a wptr.
  IsSymInterface sym =>
  HasPtrWidth wptr =>
  HasLLVMAnn sym =>
  (?lc :: TypeContext) =>
  (?memOpts :: MemOptions) =>
  sym ->
  MemImpl sym ->
  Type a ->
  CW4.XExpr sym ->
  TypeRepr tp ->
  RegValue sym tp ->
  IO (Pred sym)
computeEqualVals sym mem = loop
  where
    loop :: forall tp' a'. Type a' -> CW4.XExpr sym -> TypeRepr tp' -> RegValue sym tp' -> IO (Pred sym)
    loop Bool (CW4.XBool b) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @1) =
      isEq sym b =<< bvIsNonzero sym =<< projectLLVM_bv sym v
    loop Bool (CW4.XBool b) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @8) =
      isEq sym b =<< bvIsNonzero sym =<< projectLLVM_bv sym v
    loop Int8 (CW4.XInt8 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @8) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Int16 (CW4.XInt16 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @16) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Int32 (CW4.XInt32 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @32) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Int64 (CW4.XInt64 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @64) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Word8 (CW4.XWord8 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @8) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Word16 (CW4.XWord16 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @16) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Word32 (CW4.XWord32 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @32) =
      bvEq sym x =<< projectLLVM_bv sym v
    loop Word64 (CW4.XWord64 x) (LLVMPointerRepr w) v | Just Refl <- testEquality w (knownNat @64) =
      bvEq sym x =<< projectLLVM_bv sym v

    loop Float (CW4.XFloat x)  (FloatRepr SingleFloatRepr) v = iFloatEq @_ @SingleFloat sym x v
    loop Double (CW4.XDouble x) (FloatRepr DoubleFloatRepr) v = iFloatEq @_ @DoubleFloat sym x v

    loop (Array _ctp) CW4.XEmptyArray (VectorRepr _tpr) vs =
      pure $ backendPred sym $ V.null vs
    loop (Array ctp) (CW4.XArray xs) (VectorRepr tpr) vs
      | PVec.lengthInt xs == V.length vs
      = V.ifoldM (\pAcc i v -> andPred sym pAcc =<< loop ctp (PVec.elemAtUnsafe i xs) tpr v)
                 (truePred sym) vs
      | otherwise
      = pure (falsePred sym)
    loop (Struct struct) (CW4.XStruct xs) (StructRepr ctx) vs
      | length copilotVals == Ctx.sizeInt (Ctx.size vs)
      = ifoldlMFC (\i pAcc tpr ->
                    case copilotVals !! Ctx.indexVal i of
                      (Value ctp _, x) ->
                        andPred sym pAcc =<< loop ctp x tpr (unRV (vs Ctx.! i)))
                  (truePred sym) ctx
      | otherwise
      = pure (falsePred sym)
      where
        copilotVals :: [(Value a', CW4.XExpr sym)]
        copilotVals = zip (toValues struct) xs

    -- If we encounter a pointer, read the memory that it points to and recurse,
    -- using the Copilot type as a guide for how much memory to read. This is
    -- needed to make array- or struct-typed arguments work (see
    -- Note [Arrays and structs]), although there is nothing about this code
    -- that is array- or struct-specific. In fact, this code could also work
    -- for pointer arguments of any other type.
    loop ctp x PtrRepr v =
      do let memTy = copilotTypeToMemTypeBool8 (llvmDataLayout ?lc) ctp
             typeAlign = memTypeAlign (llvmDataLayout ?lc) memTy
         stp <- toStorableType memTy
         llvmTypeAsRepr memTy $ \tpr ->
           do regVal <- doLoad sym mem v stp tpr typeAlign
              loop ctp x tpr regVal

    loop _ctp x tpr _v =
      fail $ unlines ["Mismatch between Copilot value and crucible value", show x, show tpr]

-- | Convert a Copilot 'CT.Type' to a Crucible 'MemType'. 'CT.Bool's are
-- assumed to be one bit in size. See @Note [How LLVM represents bool]@.
copilotTypeToMemType ::
  DataLayout ->
  CT.Type a ->
  MemType
copilotTypeToMemType dl = loop
  where
    loop :: forall t. CT.Type t -> MemType
    loop CT.Bool   = i1
    loop CT.Int8   = i8
    loop CT.Int16  = i16
    loop CT.Int32  = i32
    loop CT.Int64  = i64
    loop CT.Word8  = i8
    loop CT.Word16 = i16
    loop CT.Word32 = i32
    loop CT.Word64 = i64
    loop CT.Float  = FloatType
    loop CT.Double = DoubleType
    loop t0@(CT.Array tp) =
      let len = fromIntegral (tylength t0) in
      ArrayType len (copilotTypeToMemTypeBool8 dl tp)
    loop (CT.Struct v) =
      StructType (mkStructInfo dl False (map val (CT.toValues v)))

    val :: forall t. CT.Value t -> MemType
    val (CT.Value tp _) = copilotTypeToMemTypeBool8 dl tp

-- | Like 'copilotTypeToMemType', except that 'CT.Bool's are assumed to be
-- eight bits, not one bit. See @Note [How LLVM represents bool]@.
copilotTypeToMemTypeBool8 ::
  DataLayout ->
  CT.Type a ->
  MemType
copilotTypeToMemTypeBool8 _dl CT.Bool = i8
copilotTypeToMemTypeBool8 dl tp = copilotTypeToMemType dl tp

-- | Like 'copilotTypeToMemType', except that composite types (i.e.,
-- 'CT.Array's and 'CT.Struct's) are converted to 'PtrType's instead of direct
-- 'ArrayType's or 'StructType's. See @Note [Arrays and structs]@.
copilotTypeToMemTypeCompositePtr ::
  DataLayout ->
  CT.Type a ->
  MemType
copilotTypeToMemTypeCompositePtr dl (CT.Array tp) =
  PtrType (MemType (copilotTypeToMemTypeBool8 dl tp))
copilotTypeToMemTypeCompositePtr _dl (CT.Struct struct) =
  PtrType (Alias (copilotStructIdent struct))
copilotTypeToMemTypeCompositePtr dl tp = copilotTypeToMemType dl tp

-- | Convert a Copilot 'CT.Type' to an LLVM 'L.Type'. 'CT.Bool's are
-- assumed to be one bit in size. See @Note [How LLVM represents bool]@.
copilotTypeToLLVMType ::
  CT.Type a ->
  L.Type
copilotTypeToLLVMType = loop
  where
    loop :: forall t. CT.Type t -> L.Type
    loop CT.Bool   = L.PrimType (L.Integer 1)
    loop CT.Int8   = L.PrimType (L.Integer 8)
    loop CT.Int16  = L.PrimType (L.Integer 16)
    loop CT.Int32  = L.PrimType (L.Integer 32)
    loop CT.Int64  = L.PrimType (L.Integer 64)
    loop CT.Word8  = L.PrimType (L.Integer 8)
    loop CT.Word16 = L.PrimType (L.Integer 16)
    loop CT.Word32 = L.PrimType (L.Integer 32)
    loop CT.Word64 = L.PrimType (L.Integer 64)
    loop CT.Float  = L.PrimType (L.FloatType L.Float)
    loop CT.Double = L.PrimType (L.FloatType L.Double)
    loop t0@(CT.Array tp) =
      let len = fromIntegral (tylength t0) in
      L.Array len (copilotTypeToLLVMTypeBool8 tp)
    loop (CT.Struct v) =
      L.Struct (map val (CT.toValues v))

    val :: forall t. CT.Value t -> L.Type
    val (CT.Value tp _) = copilotTypeToLLVMTypeBool8 tp

-- | Like 'copilotTypeToLLVMType', except that 'CT.Bool's are assumed to be
-- eight bits, not one bit. See @Note [How LLVM represents bool]@.
copilotTypeToLLVMTypeBool8 ::
  CT.Type a ->
  L.Type
copilotTypeToLLVMTypeBool8 CT.Bool = L.PrimType (L.Integer 8)
copilotTypeToLLVMTypeBool8 tp = copilotTypeToLLVMType tp

-- | Like 'copilotTypeToLLVMType', except that composite types (i.e.,
-- 'CT.Array's and 'CT.Struct's) are converted to 'L.PtrTo' instead of direct
-- 'L.Array's or 'L.Struct's. See @Note [Arrays and structs]@.
copilotTypeToLLVMTypeCompositePtr ::
  CT.Type a ->
  L.Type
copilotTypeToLLVMTypeCompositePtr (CT.Array tp) =
  L.PtrTo (copilotTypeToLLVMTypeBool8 tp)
copilotTypeToLLVMTypeCompositePtr (CT.Struct struct) =
  L.PtrTo (L.Alias (copilotStructIdent struct))
copilotTypeToLLVMTypeCompositePtr tp = copilotTypeToLLVMType tp

-- | Given a struct @s@, construct the name @struct.s@ as an LLVM identifier.
copilotStructIdent :: Struct a => a -> L.Ident
copilotStructIdent struct = L.Ident $ "struct." ++ typename struct

{-
Note [How LLVM represents bool]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
How are C values of type `bool` represented in LLVM? It depends. If it's being
stored directly a `bool`, it's represented with `i1` (i.e., a single bit). If
a `bool` is a member of some composite type, such as a pointer, array, or
struct, however, it's representing with `i8` (i.e., eight bits). This means
that we have to be careful when converting Bool-typed Copilot values, as they
can become `i1` or `i8` depending on the context.

copilot-verifier handles this by having both `copilotTypeToLLVMType` and
`copilotTypeToLLVMTypeBool8` functions. The former function treats `bool`s as
`i1`, whereas the latter treats `bool`s as `i8`. The former is used when
converting "top-level" types (e.g., the argument types in a trigger override),
whereas the latter is used when converting types that are part of a larger
composite type (e.g., the element type in an array).

The story for the `copilotTypeToMemType` and `copilotTypeToMemTypeBool8`
functions is similar.

Note [Arrays and structs]
~~~~~~~~~~~~~~~~~~~~~~~~~
When Clang compiles a function with an array argument, such as this trigger
function:

  void func(int32_t func_arg0[2]) { ... }

It will produce the following LLVM code:

  declare void @func(i32*) { ... }

Note that the argument is an i32*, not a [2 x i32]. As a result, we can't
translate Copilot array types directly to LLVM array types when they're used as
arguments to a function. This impedance mismatch is handled in two places:

1. The `copilotTypeToMemTypeCompositePtr`/`copilotTypeToLLVMTypeCompositePtr`
   functions special-case Copilot arrays such that they are translated to
   pointers. These functions are used when declaring the argument types of an
   override for a trigger function (see `triggerOverride`).
2. The `computeEqualVals` function has a special case for pointer
   arguments—see the case that matches on `PtrRepr`. When a `PtrRepr` is
   encounted, the underlying array values that it points to are read from
   memory. Because `PtrRepr` doesn't record the type of the thing being pointed
   to, `computeEqualVals` uses the corresponding Copilot type as a guide to
   determine how much memory to read and at what type the memory should be
   used. After this, `computeEqualVals` reads from the read array
   element-by-element—see the `VectorRepr` cases.

   Note that unlike `computeEqualVals`, `copilotExprToRegValue` does not need
   a `PtrRepr` case. This is because `copilotExprToRegValue` is ultimately used
   in service of calling writing elements of streams to memory, and streams do
   not store pointer values (at least, not in today's Copilot).

There is a very similar story for structs. Copilot passes structs by reference
in trigger functions (e.g., `void trigger(struct s *ss)`), so we must also load
from a `PtrRepr` in `computeEqualVals` to handle structs.
-}

proveObls ::
  IsSymInterface sym =>
  sym ~ ExprBuilder t st fs =>
  Logs msgs =>
  SupportsCruxLogMessage msgs =>
  CruxOptions ->
  [SolverAdapter st] ->
  IORef (LLVMAnnMap sym) ->
  SimCtxt Crux sym LLVM ->
  IO ()
proveObls cruxOpts adapters bbMapRef simctx =
  do let sym = simctx^.ctxSymInterface
     obls <- getProofObligations sym
     clearProofObligations sym

--     mapM_ (print . ppSimError) (summarizeObls sym obls)

     results <- proveGoalsOffline adapters cruxOpts simctx (explainFailure sym bbMapRef) obls
     presentResults sym results

{-
summarizeObls :: sym -> ProofObligations sym -> [SimError]
summarizeObls _ Nothing = []
summarizeObls _ (Just obls) = map (view labeledPredMsg . proofGoal) (goalsToList obls)
-}

presentResults ::
  Logs msgs =>
  IsSymInterface sym =>
  sym ->
  (ProcessedGoals, Maybe (Goals (Assumptions sym) (Assertion sym, [ProgramLoc], ProofResult sym))) ->
  IO ()
presentResults sym (num, goals)
  | numTotalGoals == 0
  = putStrLn $ "All obligations proved by concrete simplification"

    -- All goals were proven
  | numProvedGoals == numTotalGoals
  = printGoals

    -- There were some unproved goals, so fail with exit code 1
  | otherwise
  = do printGoals
       exitFailure
  where
    numTotalGoals  = totalProcessedGoals num
    numProvedGoals = provedGoals num

    printGoals =
      do putStrLn $ unwords ["Proved",show numProvedGoals, "of", show numTotalGoals, "total goals"]
         goals' <- provedGoalsTree sym goals
         case goals' of
           Just g -> logGoal g
           Nothing -> return ()
