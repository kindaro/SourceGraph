{-# LANGUAGE TypeFamilies
            , FlexibleContexts
 #-}

{-
Copyright (C) 2010 Ivan Lazar Miljenovic <Ivan.Miljenovic@gmail.com>

This file is part of SourceGraph.

SourceGraph is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Analyse.GraphRepr
   Description : Interacting with GraphData
   Copyright   : (c) Ivan Lazar Miljenovic 2009
   License     : GPL-3 or later.
   Maintainer  : Ivan.Miljenovic@gmail.com

   Interacting with GraphData from Graphalyze.
 -}
module Analyse.GraphRepr
       ( -- * General stuff
         GData(..)
       , mapData
         -- * Entity-based
       , HData'
       , mkHData'
       , origHData
       , collapsedHData
       , HData
       , mkHData
       , HSData
       , HSClustData
       , HSGraph
       , HSClustGraph
         -- ** Utility functions
       , addImplicit
       , onlyNormalCalls
       , onlyNormalCalls'
       , collapseStructures
         -- * Import-based
       , MData
       , mkMData
       , ModData
       , ModGraph
       ) where

import Parsing.Types
import Analyse.Utils(groupSortBy)
import Analyse.Colors

import Data.Graph.Analysis
import Data.Graph.Inductive
import Data.GraphViz.Attributes.Colors(Color)

import Data.List(isPrefixOf)
import qualified Data.Set as S
import Data.Set(Set)
import Control.Monad(liftM2)

-- -----------------------------------------------------------------------------

data GData n e = GD { graphData   :: GraphData n e
                    , compactData :: GraphData n (Int, e)
                    , nodeCols    :: [(Set Node, Color)]
                    }

mkGData     :: (Ord e) => (GraphData n e -> [(Set Node, Color)])
               -> GraphData n e -> GData n e
mkGData f g = GD { graphData   = g
                 , compactData = updateGraph compactSame g
                 , nodeCols    = f g
                 }

-- | Does not touch the 'nodeCols' values.  Should only touch the labels.
mapData      :: (Ord e') => (GraphData n e -> GraphData n' e')
                -> GData n e -> GData n' e'
mapData f gd = GD { graphData = gr'
                  , compactData = updateGraph compactSame gr'
                  , nodeCols = nodeCols gd
                  }
  where
    gr = graphData gd
    gr' = f gr

commonColors    :: GraphData n e -> [(Set Node, Color)]
commonColors gd = [ (rs, exportedRootColor)
                  , (es, exportedInnerColor)
                  , (ls, leafColor)
                  ]
  where
    rs = getRoots  gd
    ls = getLeaves gd
    es = getWRoots gd

getRoots :: GraphData a b -> Set Node
getRoots = S.fromList . applyAlg rootsOf'

getLeaves :: GraphData a b -> Set Node
getLeaves = S.fromList . applyAlg leavesOf'

getWRoots :: GraphData a b -> Set Node
getWRoots = S.fromList . wantedRootNodes

-- -----------------------------------------------------------------------------

type HData' = (HData, HData)

mkHData'    :: HSData -> HData'
mkHData' hs = (mkHData hs, mkHData $ collapseStructures hs)

origHData :: HData' -> HData
origHData = fst

collapsedHData :: HData' -> HData
collapsedHData = snd

type HData = GData Entity CallType

mkHData :: HSData -> HData
mkHData = mkGData entColors

type HSData = GraphData Entity CallType
type HSClustData = GraphData (GenCluster Entity) CallType
type HSGraph = AGr Entity CallType
type HSClustGraph = AGr (GenCluster Entity) CallType

entColors    :: GraphData Entity e -> [(Set Node, Color)]
entColors hd = (us, unAccessibleColor)
               : (imps, implicitExportColor)
               : commonColors hd
  where
    hd' = addImplicit hd
    us = unaccessibleNodes hd'
    imps = implicitExports hd

-- -----------------------------------------------------------------------------

onlyNormalCalls :: HSData -> HSData
onlyNormalCalls = updateGraph go
    where
      go = elfilter isNormalCall

onlyNormalCalls' :: GraphData Entity (Int, CallType)
                    -> GraphData Entity (Int, CallType)
onlyNormalCalls' = updateGraph go
  where
    go = elfilter (isNormalCall . snd)

isImplicitExport :: LNode Entity -> Bool
isImplicitExport = liftM2 (||) underscoredEntity virtClass . label

-- | Various warnings about unused/unexported entities are suppressed
--   if they start with an underscore:
--   http://www.haskell.org/ghc/docs/latest/html/users_guide/options-sanity.html
underscoredEntity :: Entity -> Bool
underscoredEntity = isPrefixOf "_" . name

virtClass                                  :: Entity -> Bool
virtClass Ent{eType = e, isVirtual = True} = case e of
                                               ClassFunction{}  -> True
                                               CollapsedClass{} -> True
                                               _                -> False
virtClass _                                = False

addImplicit :: GraphData Entity e -> GraphData Entity e
addImplicit = addRootsBy isImplicitExport

findUnderscored :: GraphData Entity e -> Set Node
findUnderscored = S.fromList
                  . map node
                  . applyAlg (filterNodes (const p))
    where
      p = underscoredEntity . label

implicitExports :: GraphData Entity e -> Set Node
implicitExports = S.fromList
                  . map node
                  . applyAlg (filterNodes (const isImplicitExport))

-- | Collapse items that must be kept together before clustering, etc.
--   Also updates wantedRootNodes.
collapseStructures :: HSData -> HSData
collapseStructures = collapseAndUpdate collapseFuncs

collapseStructures' :: HSGraph -> HSGraph
collapseStructures' = collapseAndReplace collapseFuncs

collapseFuncs :: [HSGraph -> [(NGroup, Entity)]]
collapseFuncs = [ collapseDatas
                , collapseClasses
                , collapseInsts
                ]
    where
      collapseDatas = mkCollapseTp isData getDataType mkData
      mkData m d = mkEnt m ("Data: " ++ d) (CollapsedData d)
      collapseClasses = mkCollapseTp isClass getClassName mkClass
      mkClass m c = mkEnt m ("Class: " ++ c) (CollapsedClass c)
      collapseInsts = mkCollapseTp isInstance getInstance mkInst
      mkInst m (c,d) = mkEnt m ("Class: " ++ c ++ ", Data: " ++ d)
                               (CollapsedInstance c d)

mkCollapseTp           :: (Ord a) => (EntityType -> Bool) -> (EntityType -> a)
                          -> (ModName -> a -> Entity) -> HSGraph
                          -> [(NGroup, Entity)]
mkCollapseTp p v mkE g = map lng2ne lngs
    where
      lns = filter (p . eType . snd) $ labNodes g
      lnas = map addA lns
      lngs = groupSortBy snd lnas
      lng2ne lng = ( map (fst . fst) lng
                   , mkEnt $ head lng
                   )
      mkEnt ((_,e),a) = mkE (inModule e) a
      addA ln@(_,l) = (ln, v $ eType l)

-- -----------------------------------------------------------------------------

type MData = GData ModName ()

mkMData :: ModData -> MData
mkMData = mkGData modColors

type ModData = GraphData ModName ()
type ModGraph = AGr ModName ()

modColors    :: GraphData ModName e -> [(Set Node, Color)]
modColors gd = (us, unAccessibleColor) : commonColors gd
  where
    us = unaccessibleNodes gd

-- -----------------------------------------------------------------------------
