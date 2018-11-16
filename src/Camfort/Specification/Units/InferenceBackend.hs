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
  Units of measure extension to Fortran: backend
-}

{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Camfort.Specification.Units.InferenceBackend
  ( chooseImplicitNames
  , criticalVariables
  , inconsistentConstraints
  , inferVariables
  -- mainly for debugging and testing:
  , shiftTerms
  , flattenConstraints
  , flattenUnits
  , constraintsToMatrix
  , constraintsToMatrices
  , rref
  , genUnitAssignments
  , genUnitAssignments'
  , provenance
  ) where
import           Prelude hiding ((<>))
import           Control.Arrow (first)
import           Control.Monad
import           Control.Monad.ST
import qualified Data.Array as A
import           Data.Generics.Uniplate.Operations
  (transformBi, universeBi)
import           Data.List
  ((\\), findIndex, inits, nub, partition, sortBy, group, tails, foldl')
import           Data.Ord
import qualified Data.Map.Strict as M
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import           Data.Maybe (fromMaybe, mapMaybe)
import           Data.Tuple (swap)
import           Numeric.LinearAlgebra
  ( atIndex, (<>), (><)
  , rank, (?)
  , rows, cols
  , subMatrix, diag
  , fromBlocks, ident
  )
import qualified Numeric.LinearAlgebra as H
import           Numeric.LinearAlgebra.Devel
  ( newMatrix, readMatrix
  , writeMatrix, runSTMatrix
  , freezeMatrix, STMatrix
  )

import Camfort.Specification.Units.Environment
import qualified Camfort.Specification.Units.InferenceBackendFlint as Flint

-- | Returns list of formerly-undetermined variables and their units.
inferVariables :: Constraints -> [(VV, UnitInfo)]
inferVariables cons = unitVarAssignments
  where
    unitAssignments = genUnitAssignments cons
    -- Find the rows corresponding to the distilled "unit :: var"
    -- information for ordinary (non-polymorphic) variables.
    unitVarAssignments            =
      [ (var, units) | ([UnitPow (UnitVar var)                 k], units) <- unitAssignments, k `approxEq` 1 ] ++
      [ (var, units) | ([UnitPow (UnitParamVarAbs (_, var)) k], units)    <- unitAssignments, k `approxEq` 1 ]

-- Detect inconsistency if concrete units are assigned an implicit
-- abstract unit variable with coefficients not equal, or there are
-- monomorphic literals being given parametric polymorphic units.
detectInconsistency :: [([UnitInfo], UnitInfo)] -> Constraints
detectInconsistency unitAssignments = unitAssignmentsToConstraints badImplicits ++ mustBeUnitless unitAssignments
  where
    ua' = map (shiftTerms . fmap flattenUnits) unitAssignments
    badImplicits = [ fmap foldUnits a | a@([UnitPow (UnitParamImpAbs _) k1], rhs) <- ua'
                                      , UnitPow _ k2 <- rhs
                                      , k1 /= k2 ]

-- Must be unitless: any assignments of parametric abstract units to
-- monomorphic literals.
mustBeUnitless :: [([UnitInfo], UnitInfo)] -> Constraints
mustBeUnitless unitAssignments = mbu
  where
    -- msg = "\n\n\n" ++ show unitAssignments ++ "\n\n\nmust be unitless: " ++ show mbu
    mbu = [ ConEq UnitlessLit (UnitPow (UnitLiteral l) k)
          | a@(UnitPow (UnitLiteral l) k:_, rhs) <- ua''
          , any isParametric (universeBi rhs :: [UnitInfo]) ]
    ua' = map (shiftTerms . fmap flattenUnits) unitAssignments
    ua'' = map (shiftTermsBy isLiteral . fmap flattenUnits) unitAssignments

    isLiteral UnitLiteral{} = True
    isLiteral (UnitPow UnitLiteral{} _) = True
    isLiteral _ = False

    isParametric UnitParamVarAbs{} = True
    isParametric UnitParamPosAbs{} = True
    isParametric UnitParamEAPAbs{} = True
    isParametric UnitParamLitAbs{} = True
    isParametric UnitParamImpAbs{} = True
    isParametric (UnitPow u _)     = isParametric u
    isParametric _                 = False


-- convert the assignment format back into constraints
unitAssignmentsToConstraints :: [([UnitInfo], UnitInfo)] -> Constraints
unitAssignmentsToConstraints = map (uncurry ConEq . first foldUnits)

-- | Raw units-assignment pairs.
genUnitAssignments :: Constraints -> [([UnitInfo], UnitInfo)]
genUnitAssignments cons
  -- if the results include any mappings that must be forced to be unitless...
  | mbu <- mustBeUnitless ua, not (null mbu) = genUnitAssignments (mbu ++ unitAssignmentsToConstraints ua)
  | null (detectInconsistency ua)            = ua
  | otherwise                                = []
  where
    ua = genUnitAssignments' colSort cons

genUnitAssignments' :: SortFn -> Constraints -> [([UnitInfo], UnitInfo)]
genUnitAssignments' _ [] = []
genUnitAssignments' sortfn cons
  | null colList                                      = []
  | null inconsists                                   = unitAssignments
  | otherwise                                         = []
  where
    (lhsM, rhsM, inconsists, lhsColA, rhsColA) = constraintsToMatrices' sortfn cons
    unsolvedM | rows rhsM == 0 || cols rhsM == 0 = lhsM
              | rows lhsM == 0 || cols lhsM == 0 = rhsM
              | otherwise                        = fromBlocks [[lhsM, rhsM]]

    (solvedM, newColIndices)      = Flint.normHNF unsolvedM
    -- solvedM can have additional columns and rows from normHNF;
    -- cosolvedM corresponds to the original lhsM.
    cosolvedM                     = subMatrix (0, 0) (rows solvedM, cols lhsM) solvedM
    cosolvedMrhs                  = subMatrix (0, cols lhsM) (rows solvedM, cols solvedM - cols lhsM) solvedM

    -- generate a colList with both the original columns and new ones generated
    -- if a new column generated was derived from the right-hand side then negate it
    numLhsCols                    = 1 + snd (A.bounds lhsColA)
    colList                       = map (1,) (A.elems lhsColA ++ A.elems rhsColA) ++ map genC newColIndices
    genC n | n >= numLhsCols      = (-k, UnitParamImpAbs (show u))
           | otherwise            = (k, UnitParamImpAbs (show u))
      where (k, u) = colList !! n
    -- Convert the rows of the solved matrix into flattened unit
    -- expressions in the form of "unit ** k".
    unitPow (k, u) x              = UnitPow u (k * x)
    unitPows                      = map (concatMap flattenUnits . zipWith unitPow colList) (H.toLists solvedM)

    -- Variables to the left, unit names to the right side of the equation.
    unitAssignments               = map (fmap (foldUnits . map negatePosAbs) . checkSanity . partition (not . isUnitRHS)) unitPows
    isUnitRHS (UnitPow (UnitName _) _)        = True
    isUnitRHS (UnitPow (UnitParamEAPAbs _) _) = True
    -- Because this version of isUnitRHS different from
    -- constraintsToMatrix interpretation, we need to ensure that any
    -- moved ParamPosAbs units are negated, because they are
    -- effectively being shifted across the equal-sign:
    isUnitRHS (UnitPow (UnitParamImpAbs _) _) = True
    isUnitRHS (UnitPow (UnitParamPosAbs (_, 0)) _) = False
    isUnitRHS (UnitPow (UnitParamPosAbs _) _) = True
    isUnitRHS _                               = False

checkSanity :: ([UnitInfo], [UnitInfo]) -> ([UnitInfo], [UnitInfo])
checkSanity (u1@[UnitPow (UnitVar _) _], u2)
  | or $ [ True | UnitParamPosAbs (_, i) <- universeBi u2 ]
      ++ [ True | UnitParamImpAbs _      <- universeBi u2 ] = (u1++u2,[])
checkSanity (u1@[UnitPow (UnitParamVarAbs (f, _)) _], u2)
  | or [ True | UnitParamPosAbs (f', i) <- universeBi u2, f' /= f ] = (u1++u2,[])
checkSanity c = c

--------------------------------------------------

approxEq a b = abs (b - a) < epsilon
epsilon = 0.001 -- arbitrary

--------------------------------------------------

-- Convert a set of constraints into a matrix of co-efficients, and a
-- reverse mapping of column numbers to units.
constraintsToMatrix :: Constraints -> (H.Matrix Double, [Int], A.Array Int UnitInfo)
constraintsToMatrix cons
  | all null lhs = (H.ident 0, [], A.listArray (0, -1) [])
  | otherwise = (augM, inconsists, A.listArray (0, length colElems - 1) colElems)
  where
    -- convert each constraint into the form (lhs, rhs)
    consPairs       = filter (uncurry (/=)) $ flattenConstraints cons
    -- ensure terms are on the correct side of the equal sign
    shiftedCons     = map shiftTerms consPairs
    lhs             = map fst shiftedCons
    rhs             = map snd shiftedCons
    (lhsM, lhsCols) = flattenedToMatrix colSort lhs
    (rhsM, rhsCols) = flattenedToMatrix colSort rhs
    colElems        = A.elems lhsCols ++ A.elems rhsCols
    augM            = if rows rhsM == 0 || cols rhsM == 0 then lhsM else if rows lhsM == 0 || cols lhsM == 0 then rhsM else fromBlocks [[lhsM, rhsM]]
    inconsists      = findInconsistentRows lhsM augM

constraintsToMatrices :: Constraints -> (H.Matrix Double, H.Matrix Double, [Int], A.Array Int UnitInfo, A.Array Int UnitInfo)
constraintsToMatrices cons = constraintsToMatrices' colSort cons

constraintsToMatrices' :: SortFn -> Constraints -> (H.Matrix Double, H.Matrix Double, [Int], A.Array Int UnitInfo, A.Array Int UnitInfo)
constraintsToMatrices' sortfn cons
  | all null lhs = (H.ident 0, H.ident 0, [], A.listArray (0, -1) [], A.listArray (0, -1) [])
  | otherwise = (lhsM, rhsM, inconsists, lhsCols, rhsCols)
  where
    -- convert each constraint into the form (lhs, rhs)
    consPairs       = filter (uncurry (/=)) $ flattenConstraints cons
    -- ensure terms are on the correct side of the equal sign
    shiftedCons     = map shiftTerms consPairs
    lhs             = map fst shiftedCons
    rhs             = map snd shiftedCons
    (lhsM, lhsCols) = flattenedToMatrix sortfn lhs
    (rhsM, rhsCols) = flattenedToMatrix sortfn rhs
    augM            = if rows rhsM == 0 || cols rhsM == 0 then lhsM else if rows lhsM == 0 || cols lhsM == 0 then rhsM else fromBlocks [[lhsM, rhsM]]
    inconsists      = findInconsistentRows lhsM augM

-- [[UnitInfo]] is a list of flattened constraints
flattenedToMatrix :: SortFn -> [[UnitInfo]] -> (H.Matrix Double, A.Array Int UnitInfo)
flattenedToMatrix sortfn cons = (m, A.array (0, numCols - 1) (map swap uniqUnits))
  where
    m = runSTMatrix $ do
          m <- newMatrix 0 numRows numCols
          -- loop through all constraints
          forM_ (zip cons [0..]) $ \ (unitPows, row) -> do
            -- write co-efficients for the lhs of the constraint
            forM_ unitPows $ \ (UnitPow u k) -> do
              case M.lookup u colMap of
                Just col -> readMatrix m row col >>= (writeMatrix m row col . (+k))
                _        -> return ()
          return m
    -- identify and enumerate every unit uniquely
    uniqUnits = flip zip [0..] . map head . group . sortBy sortfn $ [ u | UnitPow u _ <- concat cons ]
    -- map units to their unique column number
    colMap    = M.fromList uniqUnits
    numRows   = length cons
    numCols   = M.size colMap

negateCons = map (\ (UnitPow u k) -> UnitPow u (-k))

negatePosAbs (UnitPow (UnitParamPosAbs x) k) = UnitPow (UnitParamPosAbs x) (-k)
negatePosAbs (UnitPow (UnitParamImpAbs v) k) = UnitPow (UnitParamImpAbs v) (-k)
negatePosAbs u                               = u

--------------------------------------------------

-- Units that should appear on the right-hand-side of the matrix during solving
isUnitRHS (UnitPow (UnitName _) _)        = True
isUnitRHS (UnitPow (UnitParamEAPAbs _) _) = True
isUnitRHS _                               = False

-- | Shift UnitNames/EAPAbs poly units to the RHS, and all else to the LHS.
shiftTerms :: ([UnitInfo], [UnitInfo]) -> ([UnitInfo], [UnitInfo])
shiftTerms (lhs, rhs) = (lhsOk ++ negateCons rhsShift, rhsOk ++ negateCons lhsShift)
  where
    (lhsOk, lhsShift) = partition (not . isUnitRHS) lhs
    (rhsOk, rhsShift) = partition isUnitRHS rhs

-- | Shift terms based on function f (<- True, False ->).
shiftTermsBy :: (UnitInfo -> Bool) -> ([UnitInfo], [UnitInfo]) -> ([UnitInfo], [UnitInfo])
shiftTermsBy f (lhs, rhs) = (lhsOk ++ negateCons rhsShift, rhsOk ++ negateCons lhsShift)
  where
    (lhsOk, lhsShift) = partition f lhs
    (rhsOk, rhsShift) = partition (not . f) rhs


-- | Translate all constraints into a LHS, RHS side of units.
flattenConstraints :: Constraints -> [([UnitInfo], [UnitInfo])]
flattenConstraints = map (\ (ConEq u1 u2) -> (flattenUnits u1, flattenUnits u2))

--------------------------------------------------
-- Matrix solving functions based on HMatrix

-- | Returns given matrix transformed into Reduced Row Echelon Form
rref :: H.Matrix Double -> H.Matrix Double
rref a = snd $ rrefMatrices' a 0 0 []
  where
    -- (a', den, r) = Flint.rref a

-- Provenance of matrices.
data RRefOp
  = ElemRowSwap Int Int         -- ^ swapped row with row
  | ElemRowMult Int Double      -- ^ scaled row by constant
  | ElemRowAdds [(Int, Int)]    -- ^ set of added row onto row ops
  deriving (Show, Eq, Ord)

-- worker function
-- invariant: the matrix a is in rref except within the submatrix (j-k,j) to (n,n)
rrefMatrices' :: H.Matrix Double -> Int -> Int -> [(H.Matrix Double, RRefOp)] ->
                 ([(H.Matrix Double, RRefOp)], H.Matrix Double)
rrefMatrices' a j k mats
  -- Base cases:
  | j - k == n            = (mats, a)
  | j     == m            = (mats, a)

  -- When we haven't yet found the first non-zero number in the row, but we really need one:
  | a @@> (j - k, j) == 0 = case findIndex (/= 0) below of
    -- this column is all 0s below current row, must move onto the next column
    Nothing -> rrefMatrices' a (j + 1) (k + 1) mats
    -- we've found a row that has a non-zero element that can be swapped into this row
    Just i' -> rrefMatrices' (swapMat <> a) j k ((swapMat, ElemRowSwap i (j - k)):mats)
      where i       = j - k + i'
            swapMat = elemRowSwap n i (j - k)

  -- We have found a non-zero cell at (j - k, j), so transform it into
  -- a 1 if needed using elemRowMult, and then clear out any lingering
  -- non-zero values that might appear in the same column, using
  -- elemRowAdd:
  | otherwise             = rrefMatrices' a2 (j + 1) k mats2
  where
    n     = rows a
    m     = cols a
    below = getColumnBelow a (j - k, j)
    scale = recip (a @@> (j - k, j))
    erm   = elemRowMult n (j - k) scale

    -- scale the row if the cell is not already equal to 1
    (a1, mats1) | a @@> (j - k, j) /= 1 = (erm <> a, (erm, ElemRowMult (j - k) scale):mats)
                | otherwise             = (a, mats)

    -- Locate any non-zero values in the same column as (j - k, j) and
    -- cancel them out. Optimisation: instead of constructing a
    -- separate elemRowAdd matrix for each cancellation that are then
    -- multiplied together, simply build a single matrix that cancels
    -- all of them out at the same time, using the ST Monad.
    findAdds _ m ms
      | isWritten = (new <> m, (new, ElemRowAdds ops):ms)
      | otherwise = (m, ms)
      where
        (isWritten, ops, new) = runST $ do
          new <- newMatrix 0 n n :: ST s (STMatrix s Double)
          sequence [ writeMatrix new i' i' 1 | i' <- [0 .. (n - 1)] ]
          let f w o i | i >= n            = return (w, o)
                      | i == j - k        = f w o (i + 1)
                      | a @@> (i, j) == 0 = f w o (i + 1)
                      | otherwise         = writeMatrix new i (j - k) (- (a @@> (i, j)))
                                          >> f True ((i, j - k):o) (i + 1)
          (isWritten, ops) <- f False [] 0
          (isWritten, ops,) `fmap` freezeMatrix new

    (a2, mats2) = findAdds 0 a1 mats1

-- Get a list of values that occur below (i, j) in the matrix a.
getColumnBelow a (i, j) = concat . H.toLists $ subMatrix (i, j) (n - i, 1) a
  where n = rows a

-- 'Elementary row operation' matrices
elemRowMult :: Int -> Int -> Double -> H.Matrix Double
elemRowMult n i k = diag (H.fromList (replicate i 1.0 ++ [k] ++ replicate (n - i - 1) 1.0))

elemRowSwap :: Int -> Int -> Int -> H.Matrix Double
elemRowSwap n i j
  | i == j          = ident n
  | i > j           = elemRowSwap n j i
  | otherwise       = extractRows ([0..i-1] ++ [j] ++ [i+1..j-1] ++ [i] ++ [j+1..n-1]) $ ident n


--------------------------------------------------

type GraphCol = IM.IntMap IS.IntSet   -- graph from origin to dest.
type Provenance = IM.IntMap IS.IntSet -- graph from dest. to origin

opToGraphCol :: RRefOp -> GraphCol
opToGraphCol ElemRowMult{} = IM.empty
opToGraphCol (ElemRowSwap i j) = IM.fromList [ (i, IS.singleton j), (j, IS.singleton i) ]
opToGraphCol (ElemRowAdds l)   = IM.fromList $ concat [ [(i, IS.fromList [i,j]), (j, IS.singleton j)]  | (i, j) <- l ]

graphColCombine :: GraphCol -> GraphCol -> GraphCol
graphColCombine g1 g2 = IM.unionWith (curry snd) g1 $ IM.map (IS.fromList . trans . IS.toList) g2
  where
    trans = concatMap (\ i -> [i] `fromMaybe` (IS.toList <$> IM.lookup i g1))

invertGraphCol g = IM.fromListWith IS.union [ (i, IS.singleton j) | (j, jset) <- IM.toList g, i <- IS.toList jset ]

provenance :: H.Matrix Double -> (H.Matrix Double, Provenance)
provenance m = (m', p)
  where
    (matOps, m') = rrefMatrices' m 0 0 []
    p = invertGraphCol . foldl' graphColCombine IM.empty . map opToGraphCol $ map snd matOps

-- Worker functions:

findInconsistentRows :: H.Matrix Double -> H.Matrix Double -> [Int]
findInconsistentRows coA augA = [0..(rows augA - 1)] \\ consistent
  where
    consistent = head (filter (tryRows coA augA) (tails ( [0..(rows augA - 1)])) ++ [[]])

    -- Rouché–Capelli theorem is that if the rank of the coefficient
    -- matrix is not equal to the rank of the augmented matrix then
    -- the system of linear equations is inconsistent.
    tryRows _ _ []      = True
    tryRows coA augA ns = (rank coA' == rank augA')
      where
        coA'  = extractRows ns coA
        augA' = extractRows ns augA

extractRows = flip (?) -- hmatrix 0.17 changed interface
m @@> i = m `atIndex` i

-- | Create unique names for all of the inferred implicit polymorphic
-- unit variables.
chooseImplicitNames :: [(VV, UnitInfo)] -> [(VV, UnitInfo)]
chooseImplicitNames vars = replaceImplicitNames (genImplicitNamesMap vars) vars

genImplicitNamesMap :: Data a => a -> M.Map UnitInfo UnitInfo
genImplicitNamesMap x = M.fromList [ (absU, UnitParamEAPAbs (newN, newN)) | (absU, newN) <- zip absUnits newNames ]
  where
    absUnits = nub [ u | u@(UnitParamPosAbs _)             <- universeBi x ] ++
               nub [ u | u@(UnitParamImpAbs _)             <- universeBi x ]
    eapNames = nub $ [ n | u@(UnitParamEAPAbs (_, n))      <- universeBi x ] ++
                     [ n | u@(UnitParamEAPUse ((_, n), _)) <- universeBi x ]
    newNames = filter (`notElem` eapNames) . map ('\'':) $ nameGen
    nameGen  = concatMap sequence . tail . inits $ repeat ['a'..'z']

replaceImplicitNames :: Data a => M.Map UnitInfo UnitInfo -> a -> a
replaceImplicitNames implicitMap = transformBi replace
  where
    replace u@(UnitParamPosAbs _) = fromMaybe u $ M.lookup u implicitMap
    replace u@(UnitParamImpAbs _) = fromMaybe u $ M.lookup u implicitMap
    replace u                     = u

-- | Identifies the variables that need to be annotated in order for
-- inference or checking to work.
criticalVariables :: Constraints -> [UnitInfo]
criticalVariables [] = []
criticalVariables cons = filter (not . isUnitRHS) $ map (colA A.!) criticalIndices
  where
    (unsolvedM, _, colA)          = constraintsToMatrix cons
    solvedM                       = rref unsolvedM
    uncriticalIndices             = mapMaybe (findIndex (/= 0)) $ H.toLists solvedM
    criticalIndices               = A.indices colA \\ uncriticalIndices
    isUnitRHS (UnitName _)        = True; isUnitRHS _ = False

-- | Returns just the list of constraints that were identified as
-- being possible candidates for inconsistency, if there is a problem.
inconsistentConstraints :: Constraints -> Maybe Constraints
inconsistentConstraints [] = Nothing
inconsistentConstraints cons
  | not (null direct) = Just direct
  | null inconsists   = Nothing
  | otherwise         = Just [ con | (con, i) <- zip cons [0..], i `elem` inconsists ]
  where
    (_, _, inconsists, _, _) = constraintsToMatrices cons
    direct = detectInconsistency $ genUnitAssignments' colSort cons
