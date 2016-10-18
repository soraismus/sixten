{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, TypeFamilies, ViewPatterns, OverloadedStrings #-}
module Syntax.Abstract where

import Control.Monad
import Data.Bifunctor
import Data.Bifoldable
import Data.Bitraversable
import Data.Monoid
import Data.String
import Prelude.Extras

import Syntax
import Util

-- | Expressions with variables of type @v@ and app annotations of type @a@.
data Expr a v
  = Var v
  | Global Name
  | Con QConstr
  | Lit Literal
  | Pi !NameHint !a (Type a v) (Scope1 (Expr a) v)
  | Lam !NameHint !a (Type a v) (Scope1 (Expr a) v)
  | App (Expr a v) !a (Expr a v)
  | Case (Expr a v) (Branches QConstr a (Expr a) v)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

-- | Synonym for documentation purposes
type Type = Expr

type ExprP = Expr Plicitness
type ExprE = Expr Erasability
type TypeP = ExprP
type TypeE = ExprE

bindGlobals :: (Name -> Expr a v) -> Expr a v -> Expr a v
bindGlobals f expr = case expr of
  Var _ -> expr
  Global g -> f g
  Con _ -> expr
  Lit _ -> expr
  Pi h a t s -> Pi h a (bindGlobals f t) (bindScopeGlobals bindGlobals f s)
  Lam h a t s -> Lam h a (bindGlobals f t) (bindScopeGlobals bindGlobals f s)
  App e1 a e2 -> App (bindGlobals f e1) a (bindGlobals f e2)
  Case e brs -> Case (bindGlobals f e) (bindBranchesGlobals bindGlobals f brs)

-------------------------------------------------------------------------------
-- Instances
instance Syntax (Expr a) where
  type Annotation (Expr a) = a

  lam = Lam

  lamView (Lam n a e s) = Just (n, a, e, s)
  lamView _ = Nothing

  pi_ = Pi

  piView (Pi n a e s) = Just (n, a, e, s)
  piView _ = Nothing

  app = App

  appView (App e1 a e2) = Just (e1, a, e2)
  appView _ = Nothing

instance Eq a => Eq1 (Expr a)
instance Ord a => Ord1 (Expr a)
instance Show a => Show1 (Expr a)

instance Applicative (Expr a) where
  pure = return
  (<*>) = ap

instance Monad (Expr a) where
  return = Var
  expr >>= f = case expr of
    Var v -> f v
    Global g -> Global g
    Con c -> Con c
    Lit l -> Lit l
    Pi h a t s -> Pi h a (t >>= f) (s >>>= f)
    Lam h a t s -> Lam h a (t >>= f) (s >>>= f)
    App e1 a e2 -> App (e1 >>= f) a (e2 >>= f)
    Case e brs -> Case (e >>= f) (brs >>>= f)

instance Bifunctor Expr where
  bimap = bimapDefault

instance Bifoldable Expr where
  bifoldMap = bifoldMapDefault

instance Bitraversable Expr where
  bitraverse f g expr = case expr of
    Var v -> Var <$> g v
    Global v -> pure $ Global v
    Con c -> pure $ Con c
    Lit l -> pure $ Lit l
    Pi h a t s -> Pi h <$> f a <*> bitraverse f g t <*> bitraverseScope f g s
    Lam h a t s -> Lam h <$> f a <*> bitraverse f g t <*> bitraverseScope f g s
    App e1 a e2 -> App <$> bitraverse f g e1 <*> f a <*> bitraverse f g e2
    Case e brs  -> Case <$> bitraverse f g e <*> bitraverseBranches f g brs

instance (Eq v, IsString v, Pretty v, Eq a, PrettyAnnotation a) => Pretty (Expr a v) where
  prettyM expr = case expr of
    Var v -> prettyM v
    Global g -> prettyM g
    Con c -> prettyM c
    Lit l -> prettyM l
    Pi _ a t (unusedScope -> Just e) -> parens `above` arrPrec $
      prettyAnnotation a (prettyM t)
      <+> "->" <+>
      associate arrPrec (prettyM e)
    (usedPisViewM -> Just (tele, s)) -> withTeleHints tele $ \ns ->
      parens `above` absPrec $
      prettyTeleVarTypes ns tele <+> "->" <+>
      associate arrPrec (prettyM $ instantiateTele (pure . fromText <$> ns) s)
    Pi {} -> error "impossible prettyPrec pi"
    (lamsViewM -> Just (tele, s)) -> withTeleHints tele $ \ns ->
      parens `above` absPrec $
      "\\" <> prettyTeleVarTypes ns tele <> "." <+>
      prettyM (instantiateTele (pure . fromText <$> ns) s)
    Lam {} -> error "impossible prettyPrec lam"
    App e1 a e2 -> prettyApp (prettyM e1) (prettyAnnotation a $ prettyM e2)
    Case e brs -> parens `above` casePrec $
      "case" <+> inviolable (prettyM e) <+> "of" <$$> indent 2 (prettyM brs)
