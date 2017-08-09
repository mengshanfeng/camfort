{-
   Copyright 2016, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}

{-

  Units of measure extension to Fortran

-}

module Camfort.Specification.Units (synthesiseUnits) where

import qualified Language.Fortran.AST      as F
import qualified Language.Fortran.Analysis as FA

import           Camfort.Analysis.Annotations
import           Camfort.Specification.Units.Analysis
  (UnitsAnalysis, runInference)
import           Camfort.Specification.Units.Analysis.Consistent
  (ConsistencyError)
import           Camfort.Specification.Units.Analysis.Infer
  (InferenceReport, getInferred, inferUnits)
import qualified Camfort.Specification.Units.Annotation as UA
import           Camfort.Specification.Units.InferenceBackend (chooseImplicitNames)
import           Camfort.Specification.Units.Monad
import           Camfort.Specification.Units.Synthesis (runSynthesis)

synthesiseUnits :: Char
                -> UnitsAnalysis
                   (F.ProgramFile Annotation)
                   (Either ConsistencyError (InferenceReport, F.ProgramFile Annotation))
{-| Synthesis unspecified units for a program (after checking) -}
synthesiseUnits marker = do
  infRes <- inferUnits
  case infRes of
    Left err       -> pure $ Left err
    Right inferred -> do
      (_, state, _logs) <- runInference
        (runSynthesis marker . chooseImplicitNames . getInferred $ inferred)
      let pfUA    = usProgramFile state -- the program file after units analysis is done
          pfFinal = fmap (UA.prevAnnotation . FA.prevAnnotation) pfUA -- strip annotations
      pure . Right $ (inferred, pfFinal)
