{-# LANGUAGE DataKinds #-}

module Camfort.Specification.Stencils.LatticeModelSpec (spec) where

import Algebra.Lattice
import qualified Data.Set as S
import Data.List.NonEmpty

import Camfort.Specification.Stencils.LatticeModel

import Test.Hspec

spec :: Spec
spec =
  describe "Model spec" $ do
    describe "ioCompare" $ do
      let reg1 =
            return [ Interval 0 2 False, Interval 0 2 False ]
            \/
            return [ Interval 0 1 True, Interval 0 2 False ]
      let reg2 = return [ Interval 0 2 True, Interval 0 2 False ]
      res <- runIO $ ioCompare reg1 reg2

      it "compares equal regions" $
        res `shouldBe` EQ

      let reg3 =
            reg2 \/ return [ Interval 0 3 False, Interval 0 0 True ]
      res <- runIO $ ioCompare reg3 reg2
      it "compares greater regions" $
        res `shouldBe` GT

      let reg4 = reg1 \/ return [ InfiniteInterval, InfiniteInterval ]
      res <- runIO $ ioCompare reg3 reg4
      it "compares smaller regions" $
        res `shouldBe` LT

      let prod1 = return [ Offsets . S.fromList $ [2,3,5]
                         , Offsets . S.fromList $ [10, 15]
                         ]
      let prod2 = return [ Offsets . S.fromList $ [2,3,4,5]
                         , Offsets . S.fromList $ [10, 12, 15]
                         ]
      res <- runIO $ ioCompare prod1 prod2
      it "compare equal offset products" $
        res `shouldBe` LT

      let prod3 = prod1 \/
                  return [ Offsets . S.fromList $ [ 4 ]
                         , Offsets . S.fromList $ [ 10, 12, 15 ]
                         ] \/
                  return [ Offsets . S.fromList $ [ 2, 3, 4, 5 ]
                         , Offsets . S.fromList $ [ 12 ]
                         ]
      res <- runIO $ ioCompare prod3 prod2
      it "compare equal offset products" $
        res `shouldBe` EQ
