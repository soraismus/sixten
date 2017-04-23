{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, OverloadedStrings, PatternSynonyms, TypeFamilies #-}
module Syntax.Sized.Closed where

import Control.Monad
import Data.Bifunctor
import Data.Monoid
import Data.String
import Data.Vector(Vector)
import Data.Void
import Prelude.Extras

import Syntax hiding (lamView)
import Util

data Expr v
  = Var v
  | Global Name
  | Lit Literal
  | Con QConstr (Vector (Expr v)) -- ^ Fully applied
  | Lams (Telescope () Type Void) (Scope Tele Expr Void)
  | Call (Expr v) (Vector (Expr v))
  | PrimCall RetDir (Expr v) (Vector (Expr v, Direction))
  | Let NameHint (Expr v) (Scope1 Expr v)
  | Case (Expr v) (Branches QConstr () Expr v)
  | Prim (Primitive (Expr v))
  | ExternCode (Extern (Expr v))
  | Anno (Expr v) (Type v)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

type Type = Expr

type FunSignature = (Telescope () Type Void, Scope Tele Type Void)

-------------------------------------------------------------------------------
-- Smart constructors
apps :: Expr v -> Vector (Expr v) -> Expr v
apps (Call e es1) es2 = Call e $ es1 <> es2
apps e es = Call e es

-------------------------------------------------------------------------------
-- Helpers
pattern Sized sz e = Anno e sz

sizeOf :: Expr v -> Expr v
sizeOf (Anno _ sz) = sz
sizeOf _ = error "sizeOf"

-------------------------------------------------------------------------------
-- Instances
instance Eq1 Expr
instance Ord1 Expr
instance Show1 Expr

instance Applicative Expr where
  pure = Var
  (<*>) = ap

instance Monad Expr where
  return = pure
  expr >>= f = bind f Global expr

instance GlobalBind Expr where
  global = Global
  bind f g expr = case expr of
    Var v -> f v
    Global v -> g v
    Con c es -> Con c (bind f g <$> es)
    Lit l -> Lit l
    Lams tele s -> Lams tele s
    Call e es -> Call (bind f g e) (bind f g <$> es)
    PrimCall retDir e es -> PrimCall retDir (bind f g e) (first (bind f g) <$> es)
    Let h e s -> Let h (bind f g e) (bound f g s)
    Case e brs -> Case (bind f g e) (bound f g brs)
    Prim p -> Prim (bind f g <$> p)
    ExternCode c -> ExternCode (bind f g <$> c)
    Anno e t -> Anno (bind f g e) (bind f g t)

instance (Eq v, IsString v, Pretty v)
      => Pretty (Expr v) where
  prettyM expr = case expr of
    Var v -> prettyM v
    Global g -> prettyM g
    Con c es -> prettyApps (prettyM c) $ prettyM <$> es
    Lit l -> prettyM l
    Lams tele s -> parens `above` absPrec $
      withTeleHints tele $ \ns ->
        "\\" <> prettyTeleVarTypes ns (show <$> tele) <> "." <+>
        associate absPrec (prettyM $ instantiateTele (pure . fromName) ns $ show <$> s)
    Call e es -> prettyApps (prettyM e) (prettyM <$> es)
    PrimCall retDir f es -> "primcall" <+> prettyAnnotation retDir (prettyApps (prettyM f) $ (\(e, d) -> prettyAnnotation d $ prettyM e) <$> es)
    Let h e s -> parens `above` letPrec $ withNameHint h $ \n ->
      "let" <+> prettyM n <+> "=" <+> prettyM e <+> "in" <+>
        prettyM (Util.instantiate1 (pure $ fromName n) s)
    Case e brs -> parens `above` casePrec $
      "case" <+> inviolable (prettyM e) <+>
      "of" <$$> indent 2 (prettyM brs)
    Prim p -> prettyM $ pretty <$> p
    ExternCode c -> prettyM c
    Anno e t -> parens `above` annoPrec $
      prettyM e <+> ":" <+> prettyM t
