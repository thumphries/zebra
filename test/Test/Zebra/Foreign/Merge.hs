{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
module Test.Zebra.Foreign.Merge where

import qualified Anemone.Foreign.Mempool as Mempool
import           Anemone.Foreign.Segv (withSegv)

import           Control.Monad.Catch (bracket)

import           Disorder.Core.IO (testIO)
import           Disorder.Core.Run (disorderCheckEnvAll, ExpectedTestSpeed(..))
import           Disorder.Corpus (southpark)
import           Disorder.Jack (Property, counterexample)
import           Disorder.Jack (gamble, (===))
import           Disorder.Jack (Jack, sized)
import           Disorder.Jack (listOf, listOfN, maybeOf, choose, elements, scale)

import           P

import qualified Data.List as List
import qualified Data.Vector as Boxed
import           System.IO (IO)
import           X.Control.Monad.Trans.Either (runEitherT, firstEitherT)
import           Text.Show.Pretty (ppShow)

import           Test.Zebra.Jack
import qualified Test.Zebra.Merge.BlockC as TestMerge

import           Zebra.Foreign.Merge
import           Zebra.Foreign.Entity

import           Zebra.Data.Block
import           Zebra.Data.Core
import           Zebra.Data.Encoding
import           Zebra.Data.Entity
import           Zebra.Data.Fact


--
-- Generators
--

jEncodings :: Jack [Encoding]
jEncodings = listOfN 0 5 jEncoding

jSmallTime :: Jack Time
jSmallTime = Time <$> choose (0, 100)

jSmallPriority :: Jack Priority
jSmallPriority = Priority <$> choose (0, 100)

-- | Fact for a single entity
jFactForEntity :: (EntityHash, EntityId) -> Encoding -> AttributeId -> Jack Fact
jFactForEntity eid encoding aid =
  uncurry Fact
    <$> pure eid
    <*> pure aid
    <*> jSmallTime
    <*> jSmallPriority
    <*> (strictMaybe <$> maybeOf (jValue encoding))

-- | Generate a bunch of facts that all have the same entity
-- Used for testing merging the same entity
jFactsFor :: (EntityHash, EntityId) -> [Encoding] -> Jack [Fact]
jFactsFor eid encs = sized $ \size -> do
  let encs' = List.zip encs (fmap AttributeId [0..])
  let maxFacts = size `div` length encs
  List.sort . List.concat <$> mapM (\(enc,aid) -> listOfN 0 maxFacts $ jFactForEntity eid enc aid) encs'


jSmallEntity :: Jack (EntityHash, EntityId)
jSmallEntity =
  let
    hash eid =
      EntityHash $ unEntityHash (hashEntityId eid) `mod` 10
  in
    (\eid -> (hash eid, eid)) <$> (EntityId <$> elements southpark)

jSmallFact :: Encoding -> AttributeId -> Jack Fact
jSmallFact encoding aid =
  uncurry Fact
    <$> jSmallEntity
    <*> pure aid
    <*> jSmallTime
    <*> jSmallPriority
    <*> (strictMaybe <$> maybeOf (jValue encoding))


jSmallFacts :: [Encoding] -> Jack [Fact]
jSmallFacts encodings =
  fmap (List.sort . List.concat) .
  scale (`div` max 1 (length encodings)) $
  zipWithM (\e a -> listOf $ jSmallFact e a) encodings (fmap AttributeId [0..])

-- Some smallish number of megabytes to garbage collect by
jGarbageCollectEvery :: Jack Int64
jGarbageCollectEvery = choose (0, 10 * 1024 * 1024)




-- | Split a list of facts so it can be treated as two blocks.
-- This has to split on an entity boundary.
-- If the two blocks contained the same entity, it would be bad.
bisectBlockFacts :: Int -> [Fact] -> ([Fact],[Fact])
bisectBlockFacts split fs =
  let heads = List.take split fs
      tails = List.drop split fs
  in case tails of
      [] -> (heads, tails)
      (f:_) ->
        let (heads', tails') = dropLikeEntity f tails
        in (heads <> heads', tails')
 where
  factEntity = (,) <$> factEntityHash <*> factEntityId
  dropLikeEntity f
   = List.span (\f' -> factEntity f == factEntity f')

-- | Generate a pair of facts that can be used as blocks in a single file
jBlockPair :: (Priority -> Priority) -> [Encoding] -> Jack ([Fact],[Fact])
jBlockPair priority_mode encs = do
  fs <- jSmallFacts encs
  let fs' = fmap (\f -> f { factPriority = priority_mode $ factPriority f }) fs
  split <- choose (0, length fs')
  return $ bisectBlockFacts split fs'

-- | Construct a C Block from a bunch of facts
testForeignOfFacts :: Mempool.Mempool -> [Encoding] -> [Fact] -> IO (Block, Boxed.Vector CEntity)
testForeignOfFacts pool encs facts = do
  let Right block    = blockOfFacts (Boxed.fromList encs) (Boxed.fromList facts)
  let Right entities = entitiesOfBlock block
  es' <- mapM (foreignOfEntity pool) entities
  return (block, es')

-- | This is the slow obvious implementation to check against.
-- It sorts all the facts by entity and turns them into entities.
-- This must be a stable sort.
testMergeFacts :: [Encoding] -> [Fact] -> Boxed.Vector Entity
testMergeFacts encs facts =
  let Right block    = blockOfFacts (Boxed.fromList encs) (Boxed.fromList $ List.sortBy cmp facts)
      Right entities = entitiesOfBlock block
  in  entities
 where
  cmp a b
   = sortbits a `compare` sortbits b
  -- We are basically sorting by everything except the value
  sortbits f
   = (factEntityHash f, factEntityId f, factAttributeId f, factTime f, factPriority f)


-- | Merge facts for same entity. We should not segfault
prop_merge_1_entity_no_segfault :: Property
prop_merge_1_entity_no_segfault =
  gamble jSmallEntity $ \eid ->
  gamble jEncodings $ \encs ->
  gamble (jFactsFor eid encs) $ \facts1 ->
  gamble (jFactsFor eid encs) $ \facts2 ->
  testIO . bracket Mempool.create Mempool.free $ \pool -> withSegv (ppShow (eid, encs, facts1, facts2)) $ do
    (b1,cs1) <- testForeignOfFacts pool encs facts1
    (b2,cs2) <- testForeignOfFacts pool encs facts2
    let cs' = Boxed.zip cs1 cs2
    merged <- runEitherT $ mapM (uncurry $ mergeEntityPair pool) cs'
    -- Only checking segfault for now
    return $ counterexample (ppShow (b1,b2))
        $ case merged of
           Right _ -> True
           Left _ -> False

-- | Merge facts for same entity. We should get the right result
-- This is stable - if two facts have the same entity, time and priority, favour the first
prop_merge_1_entity_check_result :: Property
prop_merge_1_entity_check_result =
  gamble jSmallEntity $ \eid ->
  gamble jEncodings $ \encs ->
  gamble (jFactsFor eid encs) $ \facts1 ->
  gamble (jFactsFor eid encs) $ \facts2 ->
  testIO . bracket Mempool.create Mempool.free $ \pool -> withSegv (ppShow (eid, encs, facts1, facts2)) $ do
    let expect = testMergeFacts encs (facts1 <> facts2)
    (b1,cs1) <- testForeignOfFacts pool encs facts1
    (b2,cs2) <- testForeignOfFacts pool encs facts2
    let cs' = Boxed.zip cs1 cs2
    let err i = firstEitherT ppShow i
    merged <- runEitherT $ do
      ms <- err $ mapM (uncurry $ mergeEntityPair pool) cs'
      err $ mapM entityOfForeign ms

    return $ counterexample (ppShow (b1,b2))
           $ case merged of
              Right m'
                | Boxed.length cs1 == 1 && Boxed.length cs2 == 1
                -> expect === m'
                | otherwise
                -> Boxed.empty === m'
              Left  e' -> counterexample e' False


-- | Merge two blocks from two different files (one block each)
-- This is stable since we know upfront that all blocks will have their entities added
-- in a particular order.
prop_merge_1_block_2_files :: Property
prop_merge_1_block_2_files =
  gamble jEncodings $ \encs ->
  gamble (jSmallFacts encs) $ \facts1 ->
  gamble (jSmallFacts encs) $ \facts2 ->
  gamble jGarbageCollectEvery $ \gcEvery ->
  testIO . withSegv (ppShow (encs, facts1, facts2)) $ do
    let expect = testMergeFacts encs (facts1 <> facts2)
    let Right b1 = blockOfFacts (Boxed.fromList encs) (Boxed.fromList facts1)
    let Right b2 = blockOfFacts (Boxed.fromList encs) (Boxed.fromList facts2)
    let err i = firstEitherT ppShow i
    merged <- runEitherT $ err $ TestMerge.mergeLists gcEvery [[b1], [b2]]

    return $ counterexample (ppShow (b1,b2))
           $ case merged of
              Right m'
                -> Boxed.toList expect === m'
              Left  e' -> counterexample e' False

-- | Merge four blocks from two different files.
-- This should be sufficient to show it works for many files and many blocks,
-- since this tests the whole replenishment/refill loop anyway.
--
-- This is NOT stable because the block boundaries can be anywhere.
-- That means we can have the values from entity Z from file 2 block 1, then later
-- decide to read file 1 block 2, which also has values for entity Z.
--
-- Because this is not stable, we make sure there are no facts with the same key.
-- We do this by just generating even priorities for the left and odd priorities for the right.
-- This will still give us interesting sorting cases, but ensure no duplicates.
prop_merge_2_block_2_files :: Property
prop_merge_2_block_2_files =
  gamble jEncodings $ \encs ->
  gamble (jBlockPair evenPriorities encs) $ \(facts11, facts12) ->
  gamble (jBlockPair oddPriorities  encs) $ \(facts21, facts22) ->
  gamble jGarbageCollectEvery $ \gcEvery ->
  testIO . withSegv (ppShow (encs, (facts11,facts12), (facts21, facts22))) $ do
    let mkBlock = blockOfFacts (Boxed.fromList encs) . Boxed.fromList
    let expect = testMergeFacts encs (facts11 <> facts12 <> facts21 <> facts22)

    let Right b11 = mkBlock facts11
    let Right b12 = mkBlock facts12
    let Right b21 = mkBlock facts21
    let Right b22 = mkBlock facts22
    let allBlocks = [ [b11, b12], [b21, b22] ]

    let err i = firstEitherT ppShow i
    merged <- runEitherT $ err $ TestMerge.mergeLists gcEvery allBlocks

    return $ counterexample (ppShow allBlocks)
           $ case merged of
              Right m'
                -> Boxed.toList expect === m'
              Left  e' -> counterexample e' False
 where
  evenPriorities (Priority i) = Priority (i * 2)
  oddPriorities (Priority i) = Priority (i * 2 + 1)


return []
tests :: IO Bool
tests = $disorderCheckEnvAll TestRunNormal

