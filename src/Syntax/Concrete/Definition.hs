{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, FlexibleContexts, OverloadedStrings #-}
module Syntax.Concrete.Definition where

import Control.Monad
import Data.Bifunctor
import Data.Bitraversable
import Data.List.NonEmpty(NonEmpty)
import Data.String
import Data.Traversable
import Data.Vector(Vector)

import Syntax
import Syntax.Concrete.Pattern

data PatDefinition expr v
  = PatDefinition Abstract (NonEmpty (Clause expr v))
  | PatDataDefinition (DataDef expr v)
  deriving (Foldable, Functor, Show, Traversable)

data Clause expr v = Clause
  { clausePatterns :: Vector (Plicitness, Pat (PatternScope expr v) ())
  , clauseScope :: PatternScope expr v
  } deriving (Show)

-------------------------------------------------------------------------------
-- Instances
instance Traversable expr => Functor (Clause expr) where fmap = fmapDefault
instance Traversable expr => Foldable (Clause expr) where foldMap = foldMapDefault

instance Traversable expr => Traversable (Clause expr) where
  traverse f (Clause pats s)
    = Clause
    <$> traverse (traverse (bitraverse (traverse f) pure)) pats
    <*> traverse f s

instance GlobalBound PatDefinition where
  bound f g (PatDefinition a clauses) = PatDefinition a $ bound f g <$> clauses
  bound f g (PatDataDefinition dataDef) = PatDataDefinition $ bound f g dataDef

instance GlobalBound Clause where
  bound f g (Clause pats s) = Clause (fmap (first (bound f g)) <$> pats) (bound f g s)

instance (Pretty (expr v), Monad expr, IsString v)
  => PrettyNamed (Clause expr v) where
  prettyNamed name (Clause pats s)
    = withNameHints (join $ nameHints . snd <$> pats) $ \ns -> do
      let go (p, pat)
            = prettyAnnotation p
            $ prettyM $ first (instantiatePattern (pure . fromName) ns) pat
      name <+> hsep (go <$> renamePatterns ns pats)
      <+> "=" <+> prettyM (instantiatePattern (pure . fromName) ns s)

instance (Pretty (expr v), Monad expr, IsString v)
  => Pretty (Clause expr v) where
  prettyM = prettyNamed "_"

instance (Pretty (expr v), Monad expr, IsString v)
  => PrettyNamed (PatDefinition expr v) where
  prettyNamed name (PatDefinition a clauses) = prettyM a <+> vcat (prettyNamed name <$> clauses)
  prettyNamed name (PatDataDefinition dataDef) = prettyNamed name dataDef
