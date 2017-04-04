{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
module Test.Zebra.Binary.Table where

import           Disorder.Jack (Property)
import           Disorder.Jack (quickCheckAll, gamble)

import           P

import           System.IO (IO)

import           Test.Zebra.Jack
import           Test.Zebra.Util

import           Zebra.Binary.Table
import qualified Zebra.Table as Table


prop_roundtrip_table :: Property
prop_roundtrip_table =
  gamble jBinaryVersion $ \version ->
  gamble (jTable 1) $ \table ->
    trippingSerial (bTable version) (getTable version 1 $ Table.schema table) table

prop_roundtrip_column :: Property
prop_roundtrip_column =
  gamble jBinaryVersion $ \version ->
  gamble (jColumn 1) $ \column ->
    trippingSerial (bColumn version) (getColumn version 1 $ Table.schemaColumn column) column

return []
tests :: IO Bool
tests =
  $quickCheckAll