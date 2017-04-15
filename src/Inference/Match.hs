module Inference.Match where

import Control.Monad.Except
import Data.Bifoldable
import Data.Bifunctor
import Data.Bitraversable
import Data.Foldable
import Data.Function
import Data.List.NonEmpty(NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Monoid
import qualified Data.Vector as Vector
import Data.Vector(Vector)
import Prelude.Extras

import qualified Analysis.Simplify as Simplify
import qualified Builtin
import Inference.Normalise
import Inference.TypeOf
import Meta
import Syntax
import Syntax.Abstract
import Syntax.Abstract.Pattern
import Util
import VIX

type PatM = Pat AbstractM MetaA
type Clause =
  ( [PatM]
  , Expr (Var Fail MetaA)
  )

data Fail = Fail
  deriving (Eq, Ord, Show)

-- TODO can we get rid of this?
abstractF
  :: (GlobalBind e, Traversable e, Show1 e)
  => (Var Fail (MetaVar e) -> Maybe b)
  -> e (Var Fail (MetaVar e))
  -> VIX (Scope b e (Var Fail (MetaVar e)))
abstractF f e = do
  failVar <- forall mempty $ global Builtin.FailName
  let e' = unvar (\Fail -> failVar) id <$> e
      explicitFail v | v == failVar = B Fail
                     | otherwise = F v
  s <- abstractM (f . explicitFail) e'
  return $ explicitFail <$> s

fatBar :: Expr (Var Fail v) -> Expr (Var Fail v) -> Expr (Var Fail v)
fatBar e e' = case foldMap (bifoldMap (:[]) mempty) e of
  _ | Simplify.duplicable e' -> dup
  [] -> e
  [_] -> dup
  _ -> Let mempty (Lam mempty Explicit Builtin.UnitType $ abstractNone e')
    $ instantiateSome (\Fail -> App (pure $ B ()) Explicit Builtin.MkUnit)
    $ F <$> toScope e
  where
    dup = e >>= unvar (\Fail -> e') (pure . F)

matchSingle
  :: AbstractM
  -> PatM
  -> AbstractM
  -> AbstractM
  -> VIX (Expr (Var Fail MetaA))
matchSingle expr pat innerExpr retType
  = match (F <$> retType) [expr] [([pat], F <$> innerExpr)] $ F <$> innerExpr

matchCase
  :: AbstractM
  -> [(PatM, AbstractM)]
  -> AbstractM
  -> VIX (Expr (Var Fail MetaA))
matchCase expr pats retType
  = match (F <$> retType) [expr] (bimap pure (fmap F) <$> pats) (pure $ B Fail)

matchClauses
  :: [AbstractM]
  -> [([PatM], AbstractM)]
  -> AbstractM
  -> VIX (Expr (Var Fail MetaA))
matchClauses exprs pats retType
  = match (F <$> retType) exprs (fmap (fmap F) <$> pats) (pure $ B Fail)

type Match
  = Type (Var Fail MetaA) -- ^ Return type
  -> [AbstractM] -- ^ Expressions to case on corresponding to the patterns in the clauses (usually variables)
  -> [Clause] -- ^ Clauses
  -> Expr (Var Fail MetaA) -- ^ The continuation for pattern match failure
  -> VIX (Expr (Var Fail MetaA))

type NonEmptyMatch
  = Type (Var Fail MetaA) -- ^ Return type
  -> [AbstractM] -- ^ Expressions to case on corresponding to the patterns in the clauses (usually variables)
  -> NonEmpty Clause -- ^ Clauses
  -> Expr (Var Fail MetaA) -- ^ The continuation for pattern match failure
  -> VIX (Expr (Var Fail MetaA))

-- | Desugar pattern matching clauses
match :: Match
match _ _ [] expr0 = return expr0
match _ [] clauses expr0 = return $ foldr go expr0 clauses
  where
    go :: Clause -> Expr (Var Fail MetaA) -> Expr (Var Fail MetaA)
    go ([], s) x = fatBar s x
    go _ _ = error "match go"
match retType xs clauses expr0
  = foldrM
    (matchMix retType xs)
    expr0
  $ NonEmpty.groupBy ((==) `on` patternType . firstPattern) clauses

firstPattern :: ([c], b) -> c
firstPattern ([], _) = error "Match.firstPattern"
firstPattern (c:_, _) = c

matchMix :: NonEmptyMatch
matchMix retType (expr:exprs) clauses@(clause NonEmpty.:| _) expr0
  = f expr retType exprs clauses expr0
  where
    f = case patternType $ firstPattern clause of
      VarPatType -> matchVar
      LitPatType -> matchLit
      ConPatType -> matchCon
      ViewPatType _ -> matchView
matchMix _ _ _ _ = error "matchMix"

matchCon :: AbstractM -> NonEmptyMatch
matchCon expr retType exprs clauses expr0 = do
  let (QConstr typeName _) = firstCon $ NonEmpty.head clauses
  cs <- constructors typeName

  cbrs <- forM cs $ \c -> do
    let clausesStartingWithC = NonEmpty.filter ((== c) . firstCon) clauses
    -- TODO Is there a nicer way to do this?
    params <- case clausesStartingWithC of
      firstClause:_ -> return $ typeParams $ firstPattern firstClause
      [] -> do
        typ <- typeOfM expr
        typ' <- whnf typ
        let (_, params) = appsView typ'
        return $ Vector.fromList params
    (ps, ys) <- conPatArgs c params

    let exprs' = (pure <$> Vector.toList ys) ++ exprs
    rest <- match retType exprs' (decon clausesStartingWithC) (pure $ B Fail)
    restScope <- abstractF (teleAbstraction $ F <$> ys) rest
    tele <- patternTelescope ys ps
    return (c, F <$> tele, restScope)

  return $ fatBar (Case (F <$> expr) (ConBranches cbrs) retType) expr0
  where
    firstCon (c:_, _) = constr c
    firstCon _ = error "firstCon "
    typeParams (ConPat _ ps _) = ps
    typeParams _ = error "match typeParams"
    constr (ConPat c _ _) = c
    constr _ = error "match constr"
    constructors typeName = do
      (DataDefinition (DataDef cs) _, _) <- definition typeName
      return $ QConstr typeName . constrName <$> cs

conPatArgs
  :: QConstr
  -> Vector (Plicitness, AbstractM)
  -> VIX (Vector (Plicitness, PatM, AbstractM), Vector MetaA)
conPatArgs c params = do
  ctype <- qconstructor c
  let (tele, _) = pisView (ctype :: AbstractM)
      tele' = instantiatePrefix (snd <$> params) tele
  vs <- forTeleWithPrefixM tele' $ \h _ s vs ->
    forall h $ instantiateTele pure vs s
  let ps = (\(p, v) -> (p, VarPat (metaHint v) v, metaType v))
        <$> Vector.zip (teleAnnotations tele') vs
  return (ps, vs)

patternTelescope
  :: Vector MetaA
  -> Vector (a, Pat typ b, AbstractM)
  -> VIX (Telescope a Expr MetaA)
patternTelescope ys ps = Telescope <$> mapM go ps
  where
    go (p, pat, e) = do
      s <- abstractM (teleAbstraction ys) e
      return (patternHint pat, p, s)

matchLit :: AbstractM -> NonEmptyMatch
matchLit expr retType exprs clauses expr0 = do
  let ls = NonEmpty.nub $ (lit . firstPattern) <$> clauses
  lbrs <- forM ls $ \l -> do
    let clausesStartingWithL = NonEmpty.filter ((== LitPat l) . firstPattern) clauses
    rest <- match retType exprs (decon clausesStartingWithL) (pure $ B Fail)
    return (l, rest)
  return $ Case (F <$> expr) (LitBranches lbrs expr0) retType
  where
    lit (LitPat l) = l
    lit _ = error "match lit"

matchVar :: AbstractM -> NonEmptyMatch
matchVar expr retType exprs clauses expr0 = do
  clauses' <- traverse go clauses
  match retType exprs (NonEmpty.toList clauses') expr0
  where
    go :: Clause -> VIX Clause
    go (VarPat _ y:ps, s) = do
      ps' <- forM ps $ flip bitraverse pure $ \t -> do
        t' <- zonk t
        return $ subst y expr t'
      s' <- fromScope <$> zonkBound (toScope s)
      return (ps', subst (F y) (F <$> expr) s')
    go (WildcardPat:ps, s) = return (ps, s)
    go _ = error "match var"
    subst v e e' = e' >>= f
      where
        f i | i == v = e
            | otherwise = pure i

matchView :: AbstractM -> NonEmptyMatch
matchView expr retType exprs clauses = match retType (App f Explicit expr : exprs) $ NonEmpty.toList $ deview <$> clauses
  where
    f = case clauses of
      (ViewPat t _:_, _) NonEmpty.:| _ -> t
      _ -> error "error matchView f"
    deview :: Clause -> Clause
    deview (ViewPat _ p:ps, s) = (p : ps, s)
    deview _ = error "error matchView deview"

decon :: [Clause] -> [Clause]
decon clauses = [(unpat pat <> pats, b) | (pat:pats, b) <- clauses]
  where
    unpat (ConPat _ _ pats) = Vector.toList $ snd3 <$> pats
    unpat (LitPat _) = mempty
    unpat _ = error "match unpat"
