{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE ViewPatterns #-}
{-# Language OverloadedStrings #-}
{-# Language PatternGuards #-}
{-# Language PatternSynonyms #-}
{-# Language ScopedTypeVariables #-}
{-# Language GeneralizedNewtypeDeriving #-}

module Unison.Runtime.ANF
  ( optimize
  , fromTerm
  , fromTerm'
  , term
  , minimizeCyclesOrCrash
  , pattern TVar
  , pattern TLit
  , pattern TApp
  , pattern TApv
  , pattern TCom
  , pattern TCon
  , pattern TKon
  , pattern TReq
  , pattern TPrm
  , pattern TIOp
  , pattern THnd
  , pattern TLet
  , pattern TFrc
  , pattern TLets
  , pattern TName
  , pattern TBind
  , pattern TTm
  , pattern TBinds
  , pattern TBinds'
  , pattern TShift
  , pattern TMatch
  , Mem(..)
  , Lit(..)
  , SuperNormal(..)
  , SuperGroup(..)
  , POp(..)
  , IOp(..)
  , close
  , saturate
  , float
  , lamLift
  , ANormalBF(..)
  , ANormalTF(.., AApv, ACom, ACon, AKon, AReq, APrm, AIOp)
  , ANormal
  , ANormalT
  , RTag
  , CTag
  , Tag(..)
  , packTags
  , unpackTags
  , ANFM
  , Branched(..)
  , Func(..)
  , superNormalize
  , anfTerm
  , sink
  , prettyGroup
  ) where

import Unison.Prelude

import Control.Monad.Reader (ReaderT(..), asks, local)
import Control.Monad.State (State, runState, MonadState(..), modify, gets)
import Control.Lens (snoc, unsnoc)

import Data.Bifunctor (Bifunctor(..))
import Data.Bifoldable (Bifoldable(..))
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.List hiding (and,or)
import Prelude hiding (abs,and,or,seq)
import qualified Prelude
import Unison.Term hiding (resolve, fresh, float)
import Unison.Var (Var, typed)
import Unison.Util.EnumContainers as EC
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Unison.ABT as ABT
import qualified Unison.ABT.Normalized as ABTN
import qualified Unison.Term as Term
import qualified Unison.Type as Ty
import qualified Unison.Builtin.Decls as Ty (unitRef,seqViewRef)
import qualified Unison.Var as Var
import Unison.Typechecker.Components (minimize')
import Unison.Pattern (SeqOp(..))
import qualified Unison.Pattern as P
import Unison.Reference (Reference(..))
import Unison.Referent (Referent)

newtype ANF v a = ANF_ { term :: Term v a }

-- Replace all lambdas with free variables with closed lambdas.
-- Works by adding a parameter for each free variable. These
-- synthetic parameters are added before the existing lambda params.
-- For example, `(x -> x + y + z)` becomes `(y z x -> x + y + z) y z`.
-- As this replacement has the same type as the original lambda, it
-- can be done as a purely local transformation, without updating any
-- call sites of the lambda.
--
-- The transformation is shallow and doesn't transform the body of
-- lambdas it finds inside of `t`.
lambdaLift :: (Var v, Semigroup a) => (v -> v) -> Term v a -> Term v a
lambdaLift liftVar t = result where
  result = ABT.visitPure go t
  go t@(LamsNamed' vs body) = Just $ let
    fvs = ABT.freeVars t
    fvsLifted = [ (v, liftVar v) | v <- toList fvs ]
    a = ABT.annotation t
    subs = [(v, var a v') | (v,v') <- fvsLifted ]
    in if Set.null fvs then lam' a vs body -- `lambdaLift body` would make transform deep
       else apps' (lam' a (map snd fvsLifted ++ vs) (ABT.substs subs body))
                  (snd <$> subs)
  go _ = Nothing

closure :: Var v => Map v (Set v, Set v) -> Map v (Set v)
closure m0 = trace (snd <$> m0)
  where
  refs = fst <$> m0

  expand acc fvs rvs
    = fvs <> foldMap (\r -> Map.findWithDefault mempty r acc) rvs

  trace acc
    | acc == acc' = acc
    | otherwise = trace acc'
    where
    acc' = Map.intersectionWith (expand acc) acc refs

expandRec
  :: (Var v, Monoid a)
  => Set v
  -> [(v, Term v a)]
  -> [(v, Term v a)]
expandRec keep vbs = mkSub <$> fvl
  where
  mkSub (v, fvs) = (v, apps' (var mempty v) (var mempty <$> fvs))

  fvl = Map.toList
      . fmap (Set.toList)
      . closure
      $ Set.partition (`Set.member` keep)
      . ABT.freeVars
     <$> Map.fromList vbs

expandSimple
  :: (Var v, Monoid a)
  => Set v
  -> (v, Term v a)
  -> (v, Term v a)
expandSimple keep (v, bnd) = (v, apps' (var a v) evs)
  where
  a = ABT.annotation bnd
  fvs = ABT.freeVars bnd
  evs = map (var a) . Set.toList $ Set.difference fvs keep


abstract :: (Var v) => Set v -> Term v a -> Term v a
abstract keep bnd = lam' a evs bnd
  where
  a = ABT.annotation bnd
  fvs = ABT.freeVars bnd
  evs = Set.toList $ Set.difference fvs keep

enclose
  :: (Var v, Monoid a)
  => Set v
  -> (Set v -> Term v a -> Term v a)
  -> Term v a
  -> Maybe (Term v a)
enclose keep rec (LetRecNamedTop' top vbs bd)
  = Just $ letRec' top lvbs lbd
  where
  xpnd = expandRec keep' vbs
  keep' = Set.union keep . Set.fromList . map fst $ vbs
  lvbs = (map.fmap) (rec keep' . abstract keep' . ABT.substs xpnd) vbs
  lbd = rec keep' . ABT.substs xpnd $ bd
-- will be lifted, so keep this variable
enclose keep rec (Let1NamedTop' top v b@(LamsNamed' vs bd) e)
  = Just . let1' top [(v, lamb)] . rec (Set.insert v keep)
  $ ABT.subst v av e
  where
  (_, av) = expandSimple keep (v, b) 
  keep' = Set.difference keep $ Set.fromList vs
  fvs = ABT.freeVars b
  evs = Set.toList $ Set.difference fvs keep
  a = ABT.annotation b
  lbody = rec keep' bd
  lamb = lam' a (evs ++ vs) lbody
enclose keep rec t@(LamsNamed' vs body)
  = Just $ if null evs then lamb else apps' lamb $ map (var a) evs
  where
  -- remove shadowed variables
  keep' = Set.difference keep $ Set.fromList vs
  fvs = ABT.freeVars t
  evs = Set.toList $ Set.difference fvs keep
  a = ABT.annotation t
  lbody = rec keep' body
  lamb = lam' a (evs ++ vs) lbody
enclose keep rec t@(Handle' h body)
  | isStructured body
  = Just . handle (ABT.annotation t) h $ apps' lamb args
  where
  fvs = ABT.freeVars body
  evs = Set.toList $ Set.difference fvs keep
  a = ABT.annotation body
  lbody = rec keep body
  fv = Var.freshIn fvs $ typed Var.Eta
  args | null evs = [constructor a Ty.unitRef 0]
       | otherwise = var a <$> evs
  lamb | null evs = lam' a [fv] lbody
       | otherwise = lam' a evs lbody
enclose _ _ _ = Nothing

isStructured :: Var v => Term v a -> Bool
isStructured (Var' _) = False
isStructured (Lam' _) = False
isStructured (Nat' _) = False
isStructured (Int' _) = False
isStructured (Float' _) = False
isStructured (Text' _) = False
isStructured (Char' _) = False
isStructured (Constructor' _ _) = False
isStructured (Apps' Constructor'{} args) = any isStructured args
isStructured (If' b t f)
  = isStructured b || isStructured t || isStructured f
isStructured (And' l r) = isStructured l || isStructured r
isStructured (Or' l r) = isStructured l || isStructured r
isStructured _ = True

close :: (Var v, Monoid a) => Set v -> Term v a -> Term v a
close keep tm = ABT.visitPure (enclose keep close) tm

type FloatM v a r = State (Set v, [(v, Term v a)]) r

freshFloat :: Var v => Set v -> v -> v
freshFloat avoid (Var.freshIn avoid -> v0)
  = case Var.typeOf v0 of
      Var.User nm
        | v <- typed (Var.User $ nm <> w) , v `Set.notMember` avoid
        -> v
        | otherwise
        -> freshFloat (Set.insert v0 avoid) v0
      _ -> v0
  where
  w = Text.pack . show $ Var.freshId v0

letFloater
  :: (Var v, Monoid a)
  => (Term v a -> FloatM v a (Term v a))
  -> [(v, Term v a)] -> Term v a
  -> FloatM v a (Term v a)
letFloater rec vbs e = do
  cvs <- gets fst
  let shadows = [ (v, freshFloat cvs v)
                | (v, _) <- vbs, Set.member v cvs ]
      shadowMap = Map.fromList shadows
      rn v = Map.findWithDefault v v shadowMap
      shvs = Set.fromList $ map (rn.fst) vbs
  modify (first $ (<>shvs))
  fvbs <- traverse (\(v, b) -> (,) (rn v) <$> rec' (ABT.changeVars shadowMap b)) vbs
  modify (second (++ fvbs))
  pure $ ABT.changeVars shadowMap e
  where
  rec' b@(LamsNamed' vs bd) = lam' (ABT.annotation b) vs <$> rec bd
  rec' b = rec b

lamFloater
  :: (Var v, Monoid a)
  => Maybe v -> a -> [v] -> Term v a -> FloatM v a v
lamFloater mv a vs bd
  = state $ \(cvs, ctx) ->
      let v = ABT.freshIn cvs $ fromMaybe (typed Var.Float) mv
       in (v, (Set.insert v cvs, ctx <> [(v, lam' a vs bd)]))

floater
  :: (Var v, Monoid a)
  => (Term v a -> FloatM v a (Term v a))
  -> Term v a -> Maybe (FloatM v a (Term v a))
floater rec (LetRecNamed' vbs e) = Just $ letFloater rec vbs e >>= rec
floater rec (Let1Named' v b e)
  | LamsNamed' vs bd <- b
  = Just $ rec bd
       >>= lamFloater (Just v) a vs
       >>= \lv -> rec $ ABT.changeVars (Map.singleton v lv) e
  where a = ABT.annotation b
floater rec tm@(LamsNamed' vs bd) = Just $ do
  bd <- rec bd
  lv <- lamFloater Nothing a vs bd
  pure $ var a lv
  where a = ABT.annotation tm
floater _ _ = Nothing

float :: (Var v, Monoid a) => Term v a -> Term v a
float tm = case runState (go tm) (Set.empty, []) of
  (bd, (_, ctx)) -> letRec' True ctx bd
  where
  go = ABT.visit $ floater go
  -- tm | LetRecNamedTop' _ vbs e <- tm0
  --    , (pre, rec, post) <- reduceCycle vbs
  --    = let1' False pre . letRec' False rec . let1' False post $ e
  --    | otherwise = tm0

deannotate :: Var v => Term v a -> Term v a
deannotate = ABT.visitPure $ \case
  Ann' c _ -> Just $ deannotate c
  _ -> Nothing

lamLift :: (Var v, Monoid a) => Term v a -> Term v a
lamLift = float . close Set.empty . deannotate

saturate
  :: (Var v, Monoid a)
  => Map (Reference,Int) Int -> Term v a -> Term v a
saturate dat = ABT.visitPure $ \case
  Apps' f@(Constructor' r t) args -> sat r t f args
  Apps' f@(Request' r t) args -> sat r t f args
  f@(Constructor' r t) -> sat r t f []
  f@(Request' r t) -> sat r t f []
  _ -> Nothing
  where
  frsh avoid _ =
    let v = Var.freshIn avoid $ typed Var.Eta
    in (Set.insert v avoid, v)
  sat r t f args = case Map.lookup (r,t) dat of
      Just n
        | m < n
        , vs <- snd $ mapAccumL frsh fvs [1..n-m]
        , nargs <- var mempty <$> vs
        -> Just . lam' mempty vs . apps' f $ args' ++ nargs
        | m > n
        , (sargs, eargs) <- splitAt n args'
        , sv <- Var.freshIn fvs $ typed Var.Eta
        -> Just
        . let1' False [(sv,apps' f sargs)]
        $ apps' (var mempty sv) eargs
      _ -> Just (apps' f args')
    where
    m = length args
    fvs = foldMap freeVars args
    args' = saturate dat <$> args

optimize :: forall a v . (Semigroup a, Var v) => Term v a -> Term v a
optimize t = go t where
  ann = ABT.annotation
  go (Let1' b body) | canSubstLet b body = go (ABT.bind body b)
  go e@(App' f arg) = case go f of
    Lam' f -> go (ABT.bind f arg)
    f -> app (ann e) f (go arg)
  go (If' (Boolean' False) _ f) = go f
  go (If' (Boolean' True) t _) = go t
  -- todo: can simplify match expressions
  go e@(ABT.Var' _) = e
  go e@(ABT.Tm' f) = case e of
    Lam' _ -> e -- optimization is shallow - don't descend into lambdas
    _ -> ABT.tm' (ann e) (go <$> f)
  go e@(ABT.out -> ABT.Cycle body) = ABT.cycle' (ann e) (go body)
  go e@(ABT.out -> ABT.Abs v body) = ABT.abs' (ann e) v (go body)
  go e = e

  -- test for whether an expression `let x = y in body` can be
  -- reduced by substituting `y` into `body`. We only substitute
  -- when `y` is a variable or a primitive, otherwise this might
  -- end up duplicating evaluation or changing the order that
  -- effects are evaluated
  canSubstLet expr _body
    | isLeaf expr = True
    -- todo: if number of occurrences of the binding is 1 and the
    -- binding is pure, okay to substitute
    | otherwise   = False

isLeaf :: ABT.Term (F typeVar typeAnn patternAnn) v a -> Bool
isLeaf (Var' _) = True
isLeaf (Int' _) = True
isLeaf (Float' _) = True
isLeaf (Nat' _) = True
isLeaf (Text' _) = True
isLeaf (Boolean' _) = True
isLeaf (Constructor' _ _) = True
isLeaf (TermLink' _) = True
isLeaf (TypeLink' _) = True
isLeaf _ = False

minimizeCyclesOrCrash :: Var v => Term v a -> Term v a
minimizeCyclesOrCrash t = case minimize' t of
  Right t -> t
  Left e -> error $ "tried to minimize let rec with duplicate definitions: "
                 ++ show (fst <$> toList e)

fromTerm' :: (Monoid a, Var v) => (v -> v) -> Term v a -> Term v a
fromTerm' liftVar t = term (fromTerm liftVar t)

fromTerm :: forall a v . (Monoid a, Var v) => (v -> v) -> Term v a -> ANF v a
fromTerm liftVar t = ANF_ (go $ lambdaLift liftVar t) where
  ann = ABT.annotation
  isRef (Ref' _) = True
  isRef _ = False
  fixup :: Set v -- if we gotta create new vars, avoid using these
       -> ([Term v a] -> Term v a) -- do this with ANF'd args
       -> [Term v a] -- the args (not all in ANF already)
       -> Term v a -- the ANF'd term
  fixup used f args = let
    args' = Map.fromList $ toVar =<< (args `zip` [0..])
    toVar (b, i) | isLeaf b   = []
                 | otherwise = [(i, Var.freshIn used (Var.named . Text.pack $ "arg" ++ show i))]
    argsANF = map toANF (args `zip` [0..])
    toANF (b,i) = maybe b (var (ann b)) $ Map.lookup i args'
    addLet (b,i) body = maybe body (\v -> let1' False [(v,go b)] body) (Map.lookup i args')
    in foldr addLet (f argsANF) (args `zip` [(0::Int)..])
  go :: Term v a -> Term v a
  go e@(Apps' f args)
    | (isRef f || isLeaf f) && all isLeaf args = e
    | not (isRef f || isLeaf f) =
      let f' = ABT.fresh e (Var.named "f")
      in let1' False [(f', go f)] (go $ apps' (var (ann f) f') args)
    | otherwise = fixup (ABT.freeVars e) (apps' f) args
  go e@(Handle' h body)
    | isLeaf h = handle (ann e) h (go body)
    | otherwise = let h' = ABT.fresh e (Var.named "handler")
                  in let1' False [(h', go h)] (handle (ann e) (var (ann h) h') (go body))
  go e@(If' cond t f)
    | isLeaf cond = iff (ann e) cond (go t) (go f)
    | otherwise = let cond' = ABT.fresh e (Var.named "cond")
                  in let1' False [(cond', go cond)] (iff (ann e) (var (ann cond) cond') (go t) (go f))
  go e@(Match' scrutinee cases)
    | isLeaf scrutinee = match (ann e) scrutinee (fmap go <$> cases)
    | otherwise = let scrutinee' = ABT.fresh e (Var.named "scrutinee")
                  in let1' False [(scrutinee', go scrutinee)]
                      (match (ann e)
                             (var (ann scrutinee) scrutinee')
                             (fmap go <$> cases))
  -- MatchCase RHS, shouldn't conflict with LetRec
  go (ABT.Abs1NA' avs t) = ABT.absChain' avs (go t)
  go e@(And' x y)
    | isLeaf x = and (ann e) x (go y)
    | otherwise =
        let x' = ABT.fresh e (Var.named "argX")
        in let1' False [(x', go x)] (and (ann e) (var (ann x) x') (go y))
  go e@(Or' x y)
    | isLeaf x = or (ann e) x (go y)
    | otherwise =
        let x' = ABT.fresh e (Var.named "argX")
        in let1' False [(x', go x)] (or (ann e) (var (ann x) x') (go y))
  go e@(Var' _) = e
  go e@(Int' _) = e
  go e@(Nat' _) = e
  go e@(Float' _) = e
  go e@(Boolean' _) = e
  go e@(Text' _) = e
  go e@(Char' _) = e
  go e@(Blank' _) = e
  go e@(Ref' _) = e
  go e@(TermLink' _) = e
  go e@(TypeLink' _) = e
  go e@(RequestOrCtor' _ _) = e
  go e@(Lam' _) = e -- ANF conversion is shallow -
                     -- don't descend into closed lambdas
  go (Let1Named' v b e) = let1' False [(v, go b)] (go e)
  -- top = False because we don't care to emit typechecker notes about TLDs
  go (LetRecNamed' bs e) = letRec' False (fmap (second go) bs) (go e)
  go e@(Sequence' vs) =
    if all isLeaf vs then e
    else fixup (ABT.freeVars e) (seq (ann e)) (toList vs)
  go e@(Ann' tm typ) = Term.ann (ann e) (go tm) typ
  go e = error $ "ANF.term: I thought we got all of these\n" <> show e

data Mem = UN | BX deriving (Eq,Ord,Show,Enum)

-- Context entries with evaluation strategy
data CTE v s
  = ST [v] [Mem] s
  | LZ v (Either Word64 v) [v]
  deriving (Show)

pattern ST1 v m s = ST [v] [m] s

data ANormalBF v e
  = ALet [Mem] (ANormalTF v e) e
  | AName (Either Word64 v) [v] e
  | ATm (ANormalTF v e)
  deriving (Show)

data ANormalTF v e
  = ALit Lit
  | AMatch v (Branched e)
  | AShift RTag e
  | AHnd [RTag] v e
  | AApp (Func v) [v]
  | AFrc v
  | AVar v
  deriving (Show)

-- Types representing components that will go into the runtime tag of
-- a data type value. RTags correspond to references, while CTags
-- correspond to constructors.
newtype RTag = RTag Word64 deriving (Eq,Ord,Show,Read,EC.EnumKey)
newtype CTag = CTag Word16 deriving (Eq,Ord,Show,Read,EC.EnumKey)

class Tag t where rawTag :: t -> Word64
instance Tag RTag where rawTag (RTag w) = w
instance Tag CTag where rawTag (CTag w) = fromIntegral w

packTags :: RTag -> CTag -> Word64
packTags (RTag rt) (CTag ct) = ri .|. ci
  where
  ri = rt `shiftL` 16
  ci = fromIntegral ct

unpackTags :: Word64 -> (RTag, CTag)
unpackTags w = (RTag $ w `shiftR` 16, CTag . fromIntegral $ w .&. 0xFFFF)

ensureRTag :: (Ord n, Show n, Num n) => String -> n -> r -> r
ensureRTag s n x
  | n > 0xFFFFFFFFFFFF = error $ s ++ "@RTag: too large: " ++ show n
  | otherwise = x

ensureCTag :: (Ord n, Show n, Num n) => String -> n -> r -> r
ensureCTag s n x
  | n > 0xFFFF = error $ s ++ "@CTag: too large: " ++ show n
  | otherwise = x

instance Enum RTag where
  toEnum i = ensureRTag "toEnum" i . RTag $ toEnum i
  fromEnum (RTag w) = fromEnum w

instance Enum CTag where
  toEnum i = ensureCTag "toEnum" i . CTag $ toEnum i
  fromEnum (CTag w) = fromEnum w

instance Num RTag where
  fromInteger i = ensureRTag "fromInteger" i . RTag $ fromInteger i
  (+) = error "RTag: +"
  (*) = error "RTag: *"
  abs = error "RTag: abs"
  signum = error "RTag: signum"
  negate = error "RTag: negate"

instance Num CTag where
  fromInteger i = ensureCTag "fromInteger" i . CTag $ fromInteger i
  (+) = error "CTag: +"
  (*) = error "CTag: *"
  abs = error "CTag: abs"
  signum = error "CTag: signum"
  negate = error "CTag: negate"

instance Functor (ANormalBF v) where
  fmap f (ALet m bn bo) = ALet m (f <$> bn) $ f bo
  fmap f (AName n as bo) = AName n as $ f bo
  fmap f (ATm tm) = ATm $ f <$> tm

instance Bifunctor ANormalBF where
  bimap f g (ALet m bn bo) = ALet m (bimap f g bn) $ g bo
  bimap f g (AName n as bo) = AName (f <$> n) (f <$> as) $ g bo
  bimap f g (ATm tm) = ATm (bimap f g tm)

instance Bifoldable ANormalBF where
  bifoldMap f g (ALet _ b e) = bifoldMap f g b <> g e
  bifoldMap f g (AName n as e) = foldMap f n <> foldMap f as <> g e
  bifoldMap f g (ATm e) = bifoldMap f g e

instance Functor (ANormalTF v) where
  fmap _ (AVar v) = AVar v
  fmap _ (ALit l) = ALit l
  fmap f (AMatch v br) = AMatch v $ f <$> br
  fmap f (AHnd rs h e) = AHnd rs h $ f e
  fmap f (AShift i e) = AShift i $ f e
  fmap _ (AFrc v) = AFrc v
  fmap _ (AApp f args) = AApp f args

instance Bifunctor ANormalTF where
  bimap f _ (AVar v) = AVar (f v)
  bimap _ _ (ALit l) = ALit l
  bimap f g (AMatch v br) = AMatch (f v) $ fmap g br
  bimap f g (AHnd rs v e) = AHnd rs (f v) $ g e
  bimap _ g (AShift i e) = AShift i $ g e
  bimap f _ (AFrc v) = AFrc (f v)
  bimap f _ (AApp fu args) = AApp (fmap f fu) $ fmap f args

instance Bifoldable ANormalTF where
  bifoldMap f _ (AVar v) = f v
  bifoldMap _ _ (ALit _) = mempty
  bifoldMap f g (AMatch v br) = f v <> foldMap g br
  bifoldMap f g (AHnd _ h e) = f h <> g e
  bifoldMap _ g (AShift _ e) = g e
  bifoldMap f _ (AFrc v) = f v
  bifoldMap f _ (AApp func args) = foldMap f func <> foldMap f args

matchLit :: Term v a -> Maybe Lit
matchLit (Int' i) = Just $ I i
matchLit (Nat' n) = Just $ N n
matchLit (Float' f) = Just $ F f
matchLit (Text' t) = Just $ T t
matchLit (Char' c) = Just $ C c
matchLit _ = Nothing

pattern Lit' l <- (matchLit -> Just l)
pattern TLet v m bn bo = ABTN.TTm (ALet [m] bn (ABTN.TAbs v bo))
pattern TLets vs ms bn bo = ABTN.TTm (ALet ms bn (ABTN.TAbss vs bo))
pattern TName v f as bo = ABTN.TTm (AName f as (ABTN.TAbs v bo))
pattern TTm e = ABTN.TTm (ATm e)
{-# complete TLets, TName, TTm #-}

pattern TLit l = TTm (ALit l)

pattern TApp f args = TTm (AApp f args)
pattern AApv v args = AApp (FVar v) args
pattern TApv v args = TApp (FVar v) args
pattern ACom r args = AApp (FComb r) args
pattern TCom r args = TApp (FComb r) args
pattern ACon r t args = AApp (FCon r t) args
pattern TCon r t args = TApp (FCon r t) args
pattern AKon v args = AApp (FCont v) args
pattern TKon v args = TApp (FCont v) args
pattern AReq r t args = AApp (FReq r t) args
pattern TReq r t args = TApp (FReq r t) args
pattern APrm p args = AApp (FPrim (Left p)) args
pattern TPrm p args = TApp (FPrim (Left p)) args
pattern AIOp p args = AApp (FPrim (Right p)) args
pattern TIOp p args = TApp (FPrim (Right p)) args

pattern THnd rs h b = TTm (AHnd rs h b)
pattern TShift i v e = TTm (AShift i (ABTN.TAbs v e))
pattern TMatch v cs = TTm (AMatch v cs)
pattern TFrc v = TTm (AFrc v)
pattern TVar v = TTm (AVar v)

{-# complete
    TLet, TName, TVar, TApp, TFrc, TLit, THnd, TShift, TMatch
  #-}
{-# complete
      TLet, TName,
      TVar, TFrc,
      TApv, TCom, TCon, TKon, TReq, TPrm, TIOp,
      TLit, THnd, TShift, TMatch
  #-}

bind :: Var v => Cte v -> ANormal v -> ANormal v
bind (ST us ms bu) = TLets us ms bu
bind (LZ u f as) = TName u f as

unbind :: Var v => ANormal v -> Maybe (Cte v, ANormal v)
unbind (TLets us ms bu bd) = Just (ST us ms bu, bd)
unbind (TName u f as bd) = Just (LZ u f as, bd)
unbind _ = Nothing

unbinds :: Var v => ANormal v -> (Ctx v, ANormal v)
unbinds (TLets us ms bu (unbinds -> (ctx, bd))) = (ST us ms bu:ctx, bd)
unbinds (TName u f as (unbinds -> (ctx, bd))) = (LZ u f as:ctx, bd)
unbinds tm = ([], tm)

unbinds' :: Var v => ANormal v -> (Ctx v, ANormalT v)
unbinds' (TLets us ms bu (unbinds' -> (ctx, bd))) = (ST us ms bu:ctx, bd)
unbinds' (TName u f as (unbinds' -> (ctx, bd))) = (LZ u f as:ctx, bd)
unbinds' (TTm tm) = ([], tm)

pattern TBind bn bd <- (unbind -> Just (bn, bd))
  where TBind bn bd = bind bn bd

pattern TBinds :: Var v => Ctx v -> ANormal v -> ANormal v
pattern TBinds ctx bd <- (unbinds -> (ctx, bd))
  where TBinds ctx bd = foldr bind bd ctx

pattern TBinds' :: Var v => Ctx v -> ANormalT v -> ANormal v
pattern TBinds' ctx bd <- (unbinds' -> (ctx, bd))
  where TBinds' ctx bd = foldr bind (TTm bd) ctx

{-# complete TBinds' #-}

data SeqEnd = SLeft | SRight
  deriving (Eq, Ord, Enum, Show)

data Branched e
  = MatchIntegral (EnumMap Word64 e) (Maybe e)
  | MatchText (Map.Map Text e) (Maybe e)
  | MatchRequest (EnumMap RTag (EnumMap CTag ([Mem], e))) e
  | MatchEmpty
  | MatchData Reference (EnumMap CTag ([Mem], e)) (Maybe e)
  | MatchSum (EnumMap Word64 ([Mem], e))
  deriving (Show, Functor, Foldable, Traversable)

data BranchAccum v
  = AccumEmpty
  | AccumIntegral
      Reference
      (Maybe (ANormal v))
      (EnumMap Word64 (ANormal v))
  | AccumText
      (Maybe (ANormal v))
      (Map.Map Text (ANormal v))
  | AccumDefault (ANormal v)
  | AccumRequest
      (EnumMap RTag (EnumMap CTag ([Mem],ANormal v)))
      (Maybe (ANormal v))
  | AccumData
      Reference
      (Maybe (ANormal v))
      (EnumMap CTag ([Mem],ANormal v))
  | AccumSeqEmpty (ANormal v)
  | AccumSeqView
      SeqEnd
      (Maybe (ANormal v)) -- empty
      (ANormal v) -- cons/snoc
  | AccumSeqSplit
      SeqEnd
      Int -- split at
      (Maybe (ANormal v)) -- default
      (ANormal v) -- split

instance Semigroup (BranchAccum v) where
  AccumEmpty <> r = r
  l <> AccumEmpty = l
  AccumIntegral rl dl cl <> AccumIntegral rr dr cr
    | rl == rr = AccumIntegral rl (dl <|> dr) $ cl <> cr
  AccumText dl cl <> AccumText dr cr
    = AccumText (dl <|> dr) (cl <> cr)
  AccumData rl dl cl <> AccumData rr dr cr
    | rl == rr = AccumData rl (dl <|> dr) (cl <> cr)
  AccumDefault dl <> AccumIntegral r _ cr
    = AccumIntegral r (Just dl) cr
  AccumDefault dl <> AccumText _ cr
    = AccumText (Just dl) cr
  AccumDefault dl <> AccumData rr _ cr
    = AccumData rr (Just dl) cr
  AccumIntegral r dl cl <> AccumDefault dr
    = AccumIntegral r (dl <|> Just dr) cl
  AccumText dl cl <> AccumDefault dr
    = AccumText (dl <|> Just dr) cl
  AccumData rl dl cl <> AccumDefault dr
    = AccumData rl (dl <|> Just dr) cl
  AccumRequest hl dl <> AccumRequest hr dr
    = AccumRequest hm $ dl <|> dr
    where
    hm = EC.unionWith (<>) hl hr
  l@(AccumSeqEmpty _) <> AccumSeqEmpty _ = l
  AccumSeqEmpty eml <> AccumSeqView er _ cnr
    = AccumSeqView er (Just eml) cnr
  AccumSeqView el eml cnl <> AccumSeqEmpty emr
    = AccumSeqView el (eml <|> Just emr) cnl
  AccumSeqView el eml cnl <> AccumSeqView er emr _
    | el /= er
    = error "AccumSeqView: trying to merge views of opposite ends"
    | otherwise = AccumSeqView el (eml <|> emr) cnl
  AccumSeqView _ _ _ <> AccumDefault _
    = error "seq views may not have defaults"
  AccumDefault _ <> AccumSeqView _ _ _
    = error "seq views may not have defaults"
  AccumSeqSplit el nl dl bl <> AccumSeqSplit er nr dr _
    | el /= er
    = error "AccumSeqSplit: trying to merge splits at opposite ends"
    | nl /= nr
    = error
        "AccumSeqSplit: trying to merge splits at different positions"
    | otherwise
    = AccumSeqSplit el nl (dl <|> dr) bl
  AccumDefault dl <> AccumSeqSplit er nr _ br
    = AccumSeqSplit er nr (Just dl) br
  AccumSeqSplit el nl dl bl <> AccumDefault dr
    = AccumSeqSplit el nl (dl <|> Just dr) bl
  _ <> _ = error $ "cannot merge data cases for different types"

instance Monoid (BranchAccum e) where
  mempty = AccumEmpty

data Func v
  -- variable
  = FVar v
  -- top-level combinator
  | FComb !Word64
  -- continuation jump
  | FCont v
  -- data constructor
  | FCon !RTag !CTag
  -- ability request
  | FReq !RTag !CTag
  -- prim op
  | FPrim (Either POp IOp)
  deriving (Show, Functor, Foldable, Traversable)

data Lit
  = I Int64
  | N Word64
  | F Double
  | T Text
  | C Char
  | LM Referent
  | LY Reference
  deriving (Show)

litRef :: Lit -> Reference
litRef (I _) = Ty.intRef
litRef (N _) = Ty.natRef
litRef (F _) = Ty.floatRef
litRef (T _) = Ty.textRef
litRef (C _) = Ty.charRef
litRef (LM _) = Ty.termLinkRef
litRef (LY _) = Ty.typeLinkRef

data POp
  -- Int
  = ADDI | SUBI | MULI | DIVI -- +,-,*,/
  | SGNI | NEGI | MODI        -- sgn,neg,mod
  | POWI | SHLI | SHRI        -- pow,shiftl,shiftr
  | INCI | DECI | LEQI | EQLI -- inc,dec,<=,==
  -- Nat
  | ADDN | SUBN | MULN | DIVN -- +,-,*,/
  | MODN | TZRO | LZRO        -- mod,trailing/leadingZeros
  | POWN | SHLN | SHRN        -- pow,shiftl,shiftr
  | ANDN | IORN | XORN | COMN -- and,or,xor,complement
  | INCN | DECN | LEQN | EQLN -- inc,dec,<=,==
  -- Float
  | ADDF | SUBF | MULF | DIVF -- +,-,*,/
  | MINF | MAXF | LEQF | EQLF -- min,max,<=,==
  | POWF | EXPF | SQRT | LOGF -- pow,exp,sqrt,log
  | LOGB                      -- logBase
  | ABSF | CEIL | FLOR | TRNF -- abs,ceil,floor,truncate
  | RNDF                      -- round
  -- Trig
  | COSF | ACOS | COSH | ACSH -- cos,acos,cosh,acosh
  | SINF | ASIN | SINH | ASNH -- sin,asin,sinh,asinh
  | TANF | ATAN | TANH | ATNH -- tan,atan,tanh,atanh
  | ATN2                      -- atan2
  -- Text
  | CATT | TAKT | DRPT | SIZT -- ++,take,drop,size
  | UCNS | USNC | EQLT | LEQT -- uncons,unsnoc,==,<=
  | PAKT | UPKT               -- pack,unpack
  -- Sequence
  | CATS | TAKS | DRPS | SIZS -- ++,take,drop,size
  | CONS | SNOC | IDXS | BLDS -- cons,snoc,at,build
  | VWLS | VWRS | SPLL | SPLR -- viewl,viewr,splitl,splitr
  -- Bytes
  | PAKB | UPKB | TAKB | DRPB -- pack,unpack,take,drop
  | IDXB | SIZB | FLTB | CATB -- index,size,flatten,append
  -- Conversion
  | ITOF | NTOF | ITOT | NTOT
  | TTOI | TTON | TTOF | FTOT
  -- Concurrency
  | FORK
  -- Universal operations
  | EQLU | CMPU | EROR
  -- Debug
  | PRNT | INFO
  deriving (Show,Eq,Ord)

data IOp
  = OPENFI | CLOSFI | ISFEOF | ISFOPN
  | ISSEEK | SEEKFI | POSITN | STDHND
  | GBUFFR | SBUFFR
  | GTLINE | GTTEXT | PUTEXT
  | SYTIME | GTMPDR | GCURDR | SCURDR
  | DCNTNS | FEXIST | ISFDIR
  | CRTDIR | REMDIR | RENDIR
  | REMOFI | RENAFI | GFTIME | GFSIZE
  | SRVSCK | LISTEN | CLISCK | CLOSCK
  | SKACPT | SKSEND | SKRECV
  | THKILL | THDELY
  deriving (Show,Eq,Ord)

type ANormal = ABTN.Term ANormalBF
type ANormalT v = ANormalTF v (ANormal v)

type Cte v = CTE v (ANormalT v)
type Ctx v = [Cte v]

-- Should be a completely closed term
data SuperNormal v
  = Lambda { conventions :: [Mem], bound :: ANormal v }
  deriving (Show)
data SuperGroup v
  = Rec
  { group :: [(v, SuperNormal v)]
  , entry :: SuperNormal v
  } deriving (Show)

type ANFM v
  = ReaderT (Set v, Reference -> Word64, Reference -> RTag)
      (State (Word64, [(v, SuperNormal v)]))

resolveTerm :: Reference -> ANFM v Word64
resolveTerm r = asks $ \(_, rtm, _) -> rtm r

resolveType :: Reference -> ANFM v RTag
resolveType r = asks $ \(_, _, rty) -> rty r

groupVars :: ANFM v (Set v)
groupVars = asks $ \(grp, _, _) -> grp

bindLocal :: Ord v => [v] -> ANFM v r -> ANFM v r
bindLocal vs
  = local $ \(gr, rw, rt) -> (gr Set.\\ Set.fromList vs, rw, rt)

freshANF :: Var v => Word64 -> v
freshANF fr = Var.freshenId fr $ typed Var.ANFBlank

fresh :: Var v => ANFM v v
fresh = state $ \(fr, cs) -> (freshANF fr, (fr+1, cs))

contextualize :: Var v => ANormalT v -> ANFM v (Ctx v, v)
contextualize (AVar cv) = do
  gvs <- groupVars
  if cv `Set.notMember` gvs
    then pure ([], cv)
    else do fresh <&> \bv ->  ([ST1 bv BX $ AApv cv []], bv)
contextualize tm = fresh <&> \fv -> ([ST1 fv BX tm], fv)

record :: Var v => (v, SuperNormal v) -> ANFM v ()
record p = modify $ \(fr, to) -> (fr, p:to)

superNormalize
  :: Var v
  => (Reference -> Word64)
  -> (Reference -> RTag)
  -> Term v a
  -> SuperGroup v
superNormalize rtm rty tm = Rec l c
  where
  (bs, e) | LetRecNamed' bs e <- tm = (bs, e)
          | otherwise = ([], tm)
  grp = Set.fromList $ fst <$> bs
  comp = traverse_ superBinding bs *> toSuperNormal e
  subc = runReaderT comp (grp, rtm, rty)
  (c, (_,l)) = runState subc (0, [])

superBinding :: Var v => (v, Term v a) -> ANFM v ()
superBinding (v, tm) = do
  nf <- toSuperNormal tm
  modify $ \(cvs, ctx) -> (cvs, (v,nf):ctx)

toSuperNormal :: Var v => Term v a -> ANFM v (SuperNormal v)
toSuperNormal tm = do
  grp <- groupVars
  if not . Set.null . (Set.\\ grp) $ freeVars tm
    then error $ "free variables in supercombinator: " ++ show tm
    else Lambda (BX<$vs) . ABTN.TAbss vs <$> bindLocal vs (anfTerm body)
  where
  (vs, body) = fromMaybe ([], tm) $ unLams' tm

anfTerm :: Var v => Term v a -> ANFM v (ANormal v)
anfTerm tm = uncurry TBinds' <$> anfBlock tm

floatableCtx :: Ctx v -> Bool
floatableCtx = all p
  where
  p (LZ _ _ _) = True
  p (ST _ _ tm) = q tm
  q (ALit _) = True
  q (AVar _) = True
  q (ACon _ _ _) = True
  q _ = False

anfBlock :: Var v => Term v a -> ANFM v (Ctx v, ANormalT v)
anfBlock (Var' v) = pure ([], AVar v)
anfBlock (If' c t f) = do
  (cctx, cc) <- anfBlock c
  cf <- anfTerm f
  ct <- anfTerm t
  (cx, v) <- contextualize cc
  let cases = MatchData
                (Builtin $ Text.pack "Boolean")
                (EC.mapSingleton 0 ([], cf))
                (Just ct)
  pure (cctx ++ cx, AMatch v cases)
anfBlock (And' l r) = do
  (lctx, vl) <- anfArg l
  (rctx, vr) <- anfArg r
  i <- resolveTerm $ Builtin "Boolean.and"
  pure (lctx ++ rctx, ACom i [vl, vr])
anfBlock (Or' l r) = do
  (lctx, vl) <- anfArg l
  (rctx, vr) <- anfArg r
  i <- resolveTerm $ Builtin "Boolean.or"
  pure (lctx ++ rctx, ACom i [vl, vr])
anfBlock (Handle' h body)
  = anfArg h >>= \(hctx, vh) ->
    anfBlock body >>= \case
      (ctx, ACom f as) | floatableCtx ctx -> do
        v <- fresh
        pure (hctx ++ ctx ++ [LZ v (Left f) as], AApp (FVar vh) [v])
      (ctx, AApv f as) | floatableCtx ctx -> do
        v <- fresh
        pure (hctx ++ ctx ++ [LZ v (Right f) as], AApp (FVar vh) [v])
      (ctx, AVar v) | floatableCtx ctx -> do
        pure (hctx ++ ctx, AApp (FVar vh) [v])
      p@(_, _) ->
        error $ "handle body should be a simple call: " ++ show p
anfBlock (Match' scrut cas) = do
  (sctx, sc) <- anfBlock scrut
  (cx, v) <- contextualize sc
  brn <- anfCases v cas
  case brn of
    AccumDefault (TBinds' dctx df) -> do
      pure (sctx ++ cx ++ dctx, df)
    AccumRequest _ Nothing ->
      error "anfBlock: AccumRequest without default"
    AccumRequest abr (Just df) -> do
      (r, vs) <- do
        r <- fresh
        v <- fresh
        gvs <- groupVars
        let hfb = ABTN.TAbs v . TMatch v $ MatchRequest abr df
            hfvs = Set.toList $ ABTN.freeVars hfb `Set.difference` gvs
        record (r, Lambda (BX <$ hfvs ++ [v]) . ABTN.TAbss hfvs $ hfb)
        pure (r, hfvs)
      hv <- fresh
      let msc | [ST1 _ BX tm] <- cx = tm
              | [ST _ _ _] <- cx = error "anfBlock: impossible"
              | otherwise = AFrc v
      pure ( sctx ++ [LZ hv (Right r) vs]
           , AHnd (EC.keys abr) hv . TTm $ msc
           )
    AccumText df cs ->
      pure (sctx ++ cx, AMatch v $ MatchText cs df)
    AccumIntegral r df cs -> do
      i <- fresh
      let dcs = MatchData r
                  (EC.mapSingleton 0 ([UN], ABTN.TAbss [i] ics))
                  Nothing
          ics = TMatch i $ MatchIntegral cs df
      pure (sctx ++ cx, AMatch v dcs)
    AccumData r df cs ->
      pure (sctx ++ cx, AMatch v $ MatchData r cs df)
    AccumSeqEmpty _ ->
      error "anfBlock: non-exhaustive AccumSeqEmpty"
    AccumSeqView en (Just em) bd -> do
      r <- fresh
      op <- case en of
       SLeft -> resolveTerm $ Builtin "List.viewl"
       _ -> resolveTerm $ Builtin "List.viewr"
      pure ( sctx ++ cx ++ [ST1 r BX (ACom op [v])]
           , AMatch r
           $ MatchData Ty.seqViewRef
               (EC.mapFromList
                  [ (0, ([], em))
                  , (1, ([BX,BX], bd))
                  ]
               )
               Nothing
           )
    AccumSeqView {} ->
      error "anfBlock: non-exhaustive AccumSeqView"
    AccumSeqSplit en n mdf bd -> do
        i <- fresh
        r <- fresh
        t <- fresh
        pure ( sctx ++ cx ++ [lit i, split i r]
             , AMatch r . MatchSum $ mapFromList
             [ (0, ([], df t))
             , (1, ([BX,BX], bd))
             ])
      where
      op | SLeft <- en = SPLL
         | otherwise = SPLR
      lit i = ST1 i UN (ALit . N $ fromIntegral n)
      split i r = ST1 r UN (APrm op [i,v])
      df t
        = fromMaybe
            ( TLet t BX (ALit (T "non-exhaustive split"))
            $ TPrm EROR [t])
            mdf
    AccumEmpty -> pure (sctx ++ cx, AMatch v MatchEmpty)
anfBlock (Let1Named' v b e)
  = anfBlock b >>= \(bctx, cb) -> bindLocal [v] $ do
      (ectx, ce) <- anfBlock e
      pure (bctx ++ ST1 v BX cb : ectx, ce)
anfBlock (Apps' f args) = do
  (fctx, cf) <- anfFunc f
  (actx, cas) <- anfArgs args
  pure (fctx ++ actx, AApp cf cas)
anfBlock (Constructor' r t)
  = resolveType r <&> \rt -> ([], ACon rt (toEnum t) [])
anfBlock (Request' r t) = do
  r <- resolveType r
  pure ([], AReq r (toEnum t) [])
anfBlock (Boolean' b) =
  resolveType Ty.booleanRef <&> \rt -> 
    ([], ACon rt (if b then 1 else 0) [])
anfBlock (Lit' l@(T _)) =
  pure ([], ALit l)
anfBlock (Lit' l) = do
  lv <- fresh
  rt <- resolveType $ litRef l
  pure ([ST1 lv UN $ ALit l], ACon rt 0 [lv])
anfBlock (Ref' r) =
  resolveTerm r <&> \n -> ([], ACom n [])
anfBlock (Blank' _) = do
  ev <- fresh
  pure ([ST1 ev BX (ALit (T "Blank"))], APrm EROR [ev])
anfBlock (TermLink' r) = pure ([], ALit (LM r))
anfBlock (TypeLink' r) = pure ([], ALit (LY r))
anfBlock (Sequence' as) = fmap (APrm BLDS) <$> anfArgs tms
  where
  tms = toList as
anfBlock t = error $ "anf: unhandled term: " ++ show t

-- Note: this assumes that patterns have already been translated
-- to a state in which every case matches a single layer of data,
-- with no guards, and no variables ignored. This is not checked
-- completely.
anfInitCase
  :: Var v
  => v
  -> MatchCase p (Term v a)
  -> ANFM v (BranchAccum v)
anfInitCase u (MatchCase p guard (ABT.AbsN' vs bd))
  | Just _ <- guard = error "anfInitCase: unexpected guard"
  | P.Unbound _ <- p
  , [] <- vs
  = AccumDefault <$> anfBody bd
  | P.Var _ <- p
  , [v] <- vs
  = AccumDefault . ABTN.rename v u <$> anfBody bd
  | P.Var _ <- p
  = error $ "vars: " ++ show (length vs)
  | P.Int _ (fromIntegral -> i) <- p
  = AccumIntegral Ty.intRef Nothing . EC.mapSingleton i <$> anfBody bd
  | P.Nat _ i <- p
  = AccumIntegral Ty.natRef Nothing . EC.mapSingleton i <$> anfBody bd
  | P.Boolean _ b <- p
  , t <- if b then 1 else 0
  = AccumData Ty.booleanRef Nothing
  . EC.mapSingleton t . ([],) <$> anfBody bd
  | P.Text _ t <- p
  , [] <- vs
  = AccumText Nothing . Map.singleton t <$> anfBody bd
  | P.Constructor _ r t ps <- p = do
    us <- expandBindings ps vs
    AccumData r Nothing
      . EC.mapSingleton (toEnum t)
      . (BX<$us,)
      . ABTN.TAbss us
      <$> anfBody bd
  | P.EffectPure _ q <- p = do
    us <- expandBindings [q] vs
    AccumRequest mempty . Just . ABTN.TAbss us <$> anfBody bd
  | P.EffectBind _ r t ps pk <- p = do
    exp <- expandBindings (snoc ps pk) vs
    let (us, uk)
          = maybe (error "anfInitCase: unsnoc impossible") id
          $ unsnoc exp
    n <- resolveType r
    jn <- resolveTerm $ Builtin "jumpCont"
    kf <- fresh
    flip AccumRequest Nothing
       . EC.mapSingleton n
       . EC.mapSingleton (toEnum t)
       . (BX<$us,)
       . ABTN.TAbss us
       . TShift n kf
       . TName uk (Left jn) [kf]
      <$> anfBody bd
  | P.SequenceLiteral _ [] <- p
  = AccumSeqEmpty <$> anfBody bd
  | P.SequenceOp _ l op r <- p
  , Concat <- op
  , P.SequenceLiteral p ll <- l = do
    us <- expandBindings [P.Var p, r] vs
    AccumSeqSplit SLeft (length ll) Nothing
      . ABTN.TAbss us
     <$> anfBody bd
  | P.SequenceOp _ l op r <- p
  , Concat <- op
  , P.SequenceLiteral p rl <- r = do
    us <- expandBindings [l, P.Var p] vs
    AccumSeqSplit SLeft (length rl) Nothing
      . ABTN.TAbss us
     <$> anfBody bd
  | P.SequenceOp _ l op r <- p = do
    us <- expandBindings [l,r] vs
    let dir = case op of Cons -> SLeft ; _ -> SRight
    AccumSeqView dir Nothing . ABTN.TAbss us <$> anfBody bd
  where
  anfBody tm = bindLocal vs $ anfTerm tm
anfInitCase _ (MatchCase p _ _)
  = error $ "anfInitCase: unexpected pattern: " ++ show p

expandBindings'
  :: Var v
  => Word64
  -> [P.Pattern p]
  -> [v]
  -> Either String (Word64, [v])
expandBindings' fr [] [] = Right (fr, [])
expandBindings' fr (P.Unbound _:ps) vs
  = fmap (u :) <$> expandBindings' (fr+1) ps vs
  where u = freshANF fr
expandBindings' fr (P.Var _:ps) (v:vs)
  = fmap (v :) <$> expandBindings' fr ps vs
expandBindings' _ [] (_:_)
  = Left "expandBindings': more bindings than expected"
expandBindings' _ (_:_) []
  = Left "expandBindings': more patterns than expected"
expandBindings' _ _ _
  = Left $ "expandBindings': unexpected pattern"

expandBindings :: Var v => [P.Pattern p] -> [v] -> ANFM v [v]
expandBindings ps vs
  = state $ \(fr,co) -> case expandBindings' fr ps vs of
      Left err -> error $ err ++ " " ++ show (ps, vs)
      Right (fr,l) -> (l, (fr,co))

anfCases
  :: Var v
  => v
  -> [MatchCase p (Term v a)]
  -> ANFM v (BranchAccum v)
anfCases u = fmap fold . traverse (anfInitCase u)

anfFunc :: Var v => Term v a -> ANFM v (Ctx v, Func v)
anfFunc (Var' v) = pure ([], FVar v)
anfFunc (Ref' r)
  = resolveTerm r <&> \n -> ([], FComb n)
anfFunc (Constructor' r t)
  = resolveType r <&> \rt -> ([], FCon rt $ toEnum t)
anfFunc (Request' r t)
  = resolveType r <&> \rt -> ([], FReq rt $ toEnum t)
anfFunc tm = do
  (fctx, ctm) <- anfBlock tm
  (cx, v) <- contextualize ctm
  pure (fctx ++ cx, FVar v)

anfArg :: Var v => Term v a -> ANFM v (Ctx v, v)
anfArg tm = do
  (ctx, ctm) <- anfBlock tm
  (cx, v) <- contextualize ctm
  pure (ctx ++ cx, v)

anfArgs :: Var v => [Term v a] -> ANFM v (Ctx v, [v])
anfArgs tms = first concat . unzip <$> traverse anfArg tms

sink :: Var v => v -> Mem -> ANormalT v -> ANormal v -> ANormal v
sink v mtm tm = dive $ freeVarsT tm
  where
  frsh l r = Var.freshIn (l <> r) $ Var.typed Var.ANFBlank

  directVars = bifoldMap Set.singleton (const mempty)
  freeVarsT = bifoldMap Set.singleton ABTN.freeVars

  dive _ exp | v `Set.notMember` ABTN.freeVars exp = exp
  dive avoid exp@(TName u f as bo)
    | v `elem` as
    = let w = frsh avoid (ABTN.freeVars exp)
       in TLet w mtm tm $ ABTN.rename v w exp
    | otherwise
    = TName u f as (dive avoid' bo)
    where avoid' = Set.insert u avoid
  dive avoid exp@(TLets us ms bn bo)
    | v `Set.member` directVars bn -- we need to stop here
    = let w = frsh avoid (ABTN.freeVars exp)
       in TLet w mtm tm $ ABTN.rename v w exp
    | otherwise
    = TLets us ms bn' $ dive avoid' bo
    where
    avoid' = Set.fromList us <> avoid
    bn' | v `Set.notMember` freeVarsT bn = bn
        | otherwise = dive avoid' <$> bn
  dive avoid exp@(TTm tm)
    | v `Set.member` directVars tm -- same as above
    = let w = frsh avoid (ABTN.freeVars exp)
       in TLet w mtm tm $ ABTN.rename v w exp
    | otherwise = TTm $ dive avoid <$> tm

indent :: Int -> ShowS
indent ind = showString (replicate (ind*2) ' ')

prettyGroup :: Var v => SuperGroup v -> ShowS
prettyGroup (Rec grp ent)
  = showString "let rec\n"
  . foldr f id grp
  . showString "entry"
  . prettySuperNormal 1 ent
  where
  f (v,sn) r = indent 1 . pvar v
             . prettySuperNormal 2 sn . showString "\n" . r

pvar :: Var v => v -> ShowS
pvar v = showString . Text.unpack $ Var.name v

prettyVars :: Var v => [v] -> ShowS
prettyVars
  = foldr (\v r -> showString " " . pvar v . r) id

prettyLVars :: Var v => [Mem] -> [v] -> ShowS
prettyLVars [] [] = showString " "
prettyLVars (c:cs) (v:vs)
  = showString " "
  . showParen True (pvar v . showString ":" . shows c)
  . prettyLVars cs vs

prettyLVars [] (_:_) = error "more variables than conventions"
prettyLVars (_:_) [] = error "more conventions than variables"

prettyRBind :: Var v => [v] -> ShowS
prettyRBind [] = showString "()"
prettyRBind [v] = pvar v
prettyRBind (v:vs)
  = showParen True
  $ pvar v . foldr (\v r -> shows v . showString "," . r) id vs

prettySuperNormal :: Var v => Int -> SuperNormal v -> ShowS
prettySuperNormal ind (Lambda ccs (ABTN.TAbss vs tm))
  = prettyLVars ccs vs
  . showString "="
  . prettyANF False (ind+1) tm

prettyANF :: Var v => Bool -> Int -> ANormal v -> ShowS
prettyANF m ind tm = case tm of
  TLets vs _ bn bo
    -> showString "\n"
     . indent ind
     . prettyRBind vs
     . showString " ="
     . prettyANFT False (ind+1) bn
     . prettyANF True ind bo
  TName v f vs bo
    -> showString "\n"
     . indent ind
     . prettyRBind [v]
     . showString " := "
     . prettyLZF f
     . prettyVars vs
     . prettyANF True ind bo
  TTm tm
    -> prettyANFT m ind tm
  _ -> shows tm

prettySpace :: Bool -> Int -> ShowS
prettySpace False _   = showString " "
prettySpace True  ind = showString "\n" . indent ind

prettyANFT :: Var v => Bool -> Int -> ANormalT v -> ShowS
prettyANFT m ind tm = prettySpace m ind . case tm of
    ALit l -> shows l
    AFrc v -> showString "!" . pvar v
    AVar v -> pvar v
    AApp f vs -> prettyFunc f . prettyVars vs
    AMatch v bs
      -> showString "match "
       . pvar v . showString " with"
       . prettyBranches (ind+1) bs
    AShift r (ABTN.TAbss vs bo)
      -> showString "shift[" . shows r . showString "]"
       . prettyVars vs . showString "."
       . prettyANF False (ind+1) bo
    AHnd rs v bo
      -> showString "handle" . prettyTags rs
       . prettyANF False (ind+1) bo
       . showString " with " . pvar v

prettyLZF :: Var v => Either Word64 v -> ShowS
prettyLZF (Left w) = showString "ENV(" . shows w . showString ") "
prettyLZF (Right v) = pvar v . showString " "

prettyTags :: [RTag] -> ShowS
prettyTags [] = showString "{}"
prettyTags (r:rs)
  = showString "{" . shows r
  . foldr (\t r -> shows t . showString "," . r) id rs
  . showString "}"

prettyFunc :: Var v => Func v -> ShowS
prettyFunc (FVar v) = pvar v . showString " "
prettyFunc (FCont v) = pvar v . showString " "
prettyFunc (FComb w) = showString "ENV(" . shows w . showString ")"
prettyFunc (FCon r t)
  = showString "CON("
  . shows r . showString "," . shows t
  . showString ")"
prettyFunc (FReq r t)
  = showString "REQ("
  . shows r . showString "," . shows t
  . showString ")"
prettyFunc (FPrim op) = either shows shows op . showString " "

prettyBranches :: Var v => Int -> Branched (ANormal v) -> ShowS
prettyBranches ind bs = case bs of
  MatchEmpty -> showString "{}"
  MatchIntegral bs df
    -> maybe id (\e -> prettyCase ind (showString "_") e id)  df
     . foldr (uncurry $ prettyCase ind . shows) id (mapToList bs)
  MatchText bs df
    -> maybe id (\e -> prettyCase ind (showString "_") e id)  df
     . foldr (uncurry $ prettyCase ind . shows) id (Map.toList bs)
  MatchData _ bs df
    -> maybe id (\e -> prettyCase ind (showString "_") e id)  df
     . foldr (uncurry $ prettyCase ind . shows) id
         (mapToList $ snd <$> bs)
  MatchRequest bs df
    -> foldr (\(r,m) s ->
         foldr (\(c,e) -> prettyCase ind (prettyReq r c) e)
           s (mapToList $ snd <$> m))
         (prettyCase ind (prettyReq 0 0) df id) (mapToList bs)
  MatchSum bs
    -> foldr (uncurry $ prettyCase ind . shows) id
         (mapToList $ snd <$> bs)
  -- _ -> error "prettyBranches: todo"
  where
  prettyReq r c
    = showString "REQ("
    . shows r . showString "," . shows c
    . showString ")"

prettyCase :: Var v => Int -> ShowS -> ANormal v -> ShowS -> ShowS
prettyCase ind sc (ABTN.TAbss vs e) r
  = showString "\n" . indent ind . sc . prettyVars vs
  . showString " ->" . prettyANF False (ind+1) e . r
