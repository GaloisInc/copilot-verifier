{-# LANGUAGE OverloadedStrings #-}
module Copilot.Verifier.Examples (allExamples) where

import qualified Data.CaseInsensitive as CI
import Data.CaseInsensitive (CI)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Text (Text)

import Copilot.Verifier (Verbosity)
import qualified Copilot.Verifier.Examples.Array   as Array
import qualified Copilot.Verifier.Examples.Arith   as Arith
import qualified Copilot.Verifier.Examples.Clock   as Clock
import qualified Copilot.Verifier.Examples.Counter as Counter
import qualified Copilot.Verifier.Examples.Engine  as Engine
import qualified Copilot.Verifier.Examples.FPOps   as FPOps
import qualified Copilot.Verifier.Examples.Heater  as Heater
import qualified Copilot.Verifier.Examples.IntOps  as IntOps
import qualified Copilot.Verifier.Examples.Structs as Structs
import qualified Copilot.Verifier.Examples.Voting  as Voting
import qualified Copilot.Verifier.Examples.WCV     as WCV

allExamples :: Verbosity -> Map (CI Text) (IO ())
allExamples verb = Map.fromList
    [ example "Array" (Array.verifySpec verb)
    , example "Arith" (Arith.verifySpec verb)
    , example "Clock" (Clock.verifySpec verb)
    , example "Counter" (Counter.verifySpec verb)
    , example "Engine" (Engine.verifySpec verb)
    , example "FPOps" (FPOps.verifySpec verb)
    , example "Heater" (Heater.verifySpec verb)
    , example "IntOps" (IntOps.verifySpec verb)
    , example "Structs" (Structs.verifySpec verb)
    , example "Voting" (Voting.verifySpec verb)
    , example "WCV" (WCV.verifySpec verb)
    ]
  where
    example :: Text -> IO () -> (CI Text, IO ())
    example name action = (CI.mk name, action)
