{-# LANGUAGE BangPatterns, ViewPatterns, MonadComprehensions #-}
module Analysis.Simplify where

import Bound
import Data.Bifunctor
import Data.Foldable as Foldable
import Data.Maybe
import qualified Data.MultiSet as MultiSet
import qualified Data.Set as Set
import qualified Data.Vector as Vector

import qualified Builtin.Names as Builtin
import Elaboration.Normalise
import Syntax
import Syntax.Core hiding (let_)
import Util

simplifyExpr
  :: (QName -> Bool)
  -> Int
  -> Expr meta v
  -> Expr meta v
simplifyExpr glob !applied expr = case expr of
  Var _ -> expr
  Meta v es -> Meta v $ fmap (simplifyExpr glob 0) <$> es
  Global _ -> expr
  Builtin.Zero -> Lit $ Natural 0
  Builtin.Succ n -> case simplifyExpr glob 0 n of
    Lit (Natural n') -> Lit $ Natural $ n' + 1
    n' -> Builtin.Succ n'
  Con _ -> expr
  Lit _ -> expr
  Pi h a t s -> Pi h a (simplifyExpr glob 0 t) $ hoist (simplifyExpr glob 0) s
  (lamsViewM -> Just (tele, s)) ->
    etaLams
      glob
      applied
      tele
      $ hoist (simplifyExpr glob $ max 0 $ applied - teleLength tele) s
  Lam {} -> error "simplifyExpr Lam"
  App e1 p e2 ->
    betaApp
      (simplifyExpr glob (applied + 1) e1)
      p
      (simplifyExpr glob 0 e2)
  Case e brs retType -> do
    let e' = simplifyExpr glob 0 e
    case chooseBranch e' brs of
      Nothing -> Case e' (hoist (simplifyExpr glob applied) brs) (simplifyExpr glob 0 retType)
      Just chosen -> simplifyExpr glob applied chosen
  Let ds s -> letRec glob (hoist (simplifyExpr glob 0) ds) $ hoist (simplifyExpr glob applied) s
  ExternCode c retType ->
    ExternCode
      (simplifyExpr glob 0 <$> c)
      (simplifyExpr glob 0 retType)
  SourceLoc loc e -> SourceLoc loc $ simplifyExpr glob applied e

-- TODO: Inlining can expose more simplification opportunities that aren't exploited.
letRec
  :: (QName -> Bool)
  -> LetRec (Expr meta) v
  -> Scope LetVar (Expr meta) v
  -> Expr meta v
letRec glob ds scope
  | Vector.null ds' = instantiate (error "letRec empty") scope'
  | Vector.length (unLetRec ds) /= Vector.length ds' = simplifyExpr glob 0 $ Let (LetRec ds') scope'
  | otherwise = Let (LetRec ds') scope'
  where
    occs = MultiSet.fromList (bindings scope)
      <> foldMap (MultiSet.fromList . bindings) (letBodies ds)
    dsFilter = iforLet ds $ \i h loc s t -> do
      let e = fromScope s
          v = LetVar i
          s' = rebind rebinding s
      if duplicable e || MultiSet.occur v occs <= 1 && terminates glob e
        then (mempty, s')
        else (pure (v, LetBinding h loc s' t), Scope $ pure $ B $ permute v)
    rebinding (LetVar v) = snd $ dsFilter Vector.! v
    oldVarsNewDs = Vector.concatMap fst dsFilter
    permute = LetVar . fromJust . hashedElemIndex (fst <$> oldVarsNewDs)

    ds' = snd <$> oldVarsNewDs
    scope' = rebind rebinding scope

let_
  :: (QName -> Bool)
  -> NameHint
  -> SourceLoc
  -> Expr meta v
  -> Type meta v
  -> Scope1 (Expr meta) v
  -> Expr meta v
let_ glob h loc e t s
  = letRec
    glob
    (LetRec $ pure $ LetBinding h loc (abstractNone e) t)
    (mapBound (\() -> 0) s)

simplifyDef
  :: (QName -> Bool)
  -> Definition (Expr meta) v
  -> Definition (Expr meta) v
simplifyDef glob = hoist $ simplifyExpr glob 0

etaLams
  :: (QName -> Bool)
  -> Int
  -> Telescope Plicitness (Expr meta) v
  -> Scope TeleVar (Expr meta) v
  -> Expr meta v
etaLams glob applied tele scope = case go 0 $ fromScope scope of
  Nothing -> quantify Lam tele scope
  Just (i, expr) -> quantify Lam (takeTele (len - i) tele) $ toScope expr
  where
    go i (App e a (Var (B n)))
      | n == TeleVar (len - i')
      , a == as Vector.! unTeleVar n
      , B n `Set.notMember` toSet (second (const ()) <$> e)
      = case go i' e of
        Nothing | etaAllowed e i' -> Just (i', e)
        res -> res
      where
        i' = i + 1
    go _ _ = Nothing
    etaAllowed e n
      = applied >= n -- termination doesn't matter since the expression is applied anyway
      || terminates glob e -- Use glob for termination to e.g. avoid making `loop = loop` out of `loop x = loop x`
    len = teleLength tele
    as = teleAnnotations tele

betaApp ::  Expr meta v -> Plicitness -> Expr meta v -> Expr meta v
betaApp (sourceLocView -> (loc, Lam h a1 t s)) a2 e2 | a1 == a2 = let_ (const True) h loc e2 t s
betaApp e1 a e2 = App e1 a e2

betaApps
  :: Foldable t
  => Expr meta v
  -> t (Plicitness, Expr meta v)
  -> Expr meta v
betaApps = Foldable.foldl (uncurry . betaApp)

-- | Is it cost-free to duplicate this expression?
duplicable :: Expr meta v -> Bool
duplicable expr = case expr of
  Var _ -> True
  Meta _ _ -> False
  Global _ -> True
  Con _ -> True
  Lit _ -> True
  Pi {} -> True
  Lam {} -> False
  App {} -> False
  Case {} -> False
  Let {} -> False
  ExternCode {} -> False
  SourceLoc _ e -> duplicable e

terminates :: (QName -> Bool) -> Expr meta v -> Bool
terminates glob expr = case expr of
  Var _ -> True
  Meta _ _ -> False
  Global n -> glob n
  Con _ -> True
  Lit _ -> True
  Pi {} -> True
  Lam {} -> True
  App e1 _ e2 -> terminatesWhenCalled glob e1 && terminates glob e2
  Case {} -> False
  Let ds s -> all (terminates glob) (fromScope <$> letBodies ds) && terminates glob (fromScope s)
  ExternCode {} -> False
  SourceLoc _ e -> terminates glob e

terminatesWhenCalled :: (QName -> Bool) -> Expr meta v -> Bool
terminatesWhenCalled glob expr = case expr of
  Var _ -> False
  Meta _ _ -> False
  Global _ -> False
  Con _ -> True
  Lit _ -> True
  Pi {} -> True
  Lam {} -> False
  App {} -> False
  Case {} -> False
  Let ds s -> all (terminates glob) (fromScope <$> letBodies ds) && terminatesWhenCalled glob (fromScope s)
  ExternCode {} -> False
  SourceLoc _ e -> terminatesWhenCalled glob e
