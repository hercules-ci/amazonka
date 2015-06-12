{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

-- Module      : Compiler.AST.Data.Syntax
-- Copyright   : (c) 2013-2015 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Compiler.AST.Data.Syntax where

import           Compiler.AST.Data.Field
import           Compiler.AST.Data.Instance
import           Compiler.AST.TypeOf
import           Compiler.Formatting
import           Compiler.Protocol
import           Compiler.Text
import           Compiler.Types
import           Control.Comonad
import           Control.Comonad.Cofree
import           Control.Error
import           Control.Lens                 hiding (iso, mapping, op)
import qualified Data.Foldable                as Fold
import           Data.Function                ((&))
import qualified Data.HashMap.Strict          as Map
import           Data.List                    (nub)
import           Data.Monoid
import           Data.Text                    (Text)
import qualified Data.Text                    as Text
import           Debug.Trace
import qualified Language.Haskell.Exts        as Exts
import           Language.Haskell.Exts.Build  hiding (pvar, var)
import           Language.Haskell.Exts.SrcLoc (noLoc)
import           Language.Haskell.Exts.Syntax hiding (Int, List, Lit, Var)

ctorSig :: Timestamp -> Id -> [Field] -> Decl
ctorSig ts n = TypeSig noLoc [n ^. smartCtorId . to ident]
    . Fold.foldr' TyFun (n ^. typeId . to tycon)
    . map (external ts)
    . filter (^. fieldRequired)

ctorDecl :: Id -> [Field] -> Decl
ctorDecl n fs = sfun noLoc name ps (UnGuardedRhs rhs) noBinds
  where
    name :: Name
    name = n ^. smartCtorId . to ident

    ps :: [Name]
    ps = map (view fieldParam) (filter (view fieldRequired) fs)

    rhs :: Exp
    rhs | null fs   = var (n ^. ctorId)
        | otherwise = RecConstr (n ^. ctorId . to unqual) (map fieldUpdate fs)

fieldUpdate :: Field -> FieldUpdate
fieldUpdate f = FieldUpdate (f ^. fieldAccessor . to unqual) set'
  where
    set' | opt, f ^. fieldMonoid    = var "mempty"
         | opt                      = var "Nothing"
         | Just v <- iso (typeOf f) = infixApp v "#" p
         | otherwise                = p

    opt = not (f ^. fieldRequired)

    p = Exts.Var (UnQual (f ^. fieldParam))

lensSig :: Timestamp -> TType -> Field -> Decl
lensSig ts t f = TypeSig noLoc [ident (f ^. fieldLens)] $
    TyApp (TyApp (tycon "Lens'")
                 (signature ts t)) (external ts f)

lensDecl :: Field -> Decl
lensDecl f = sfun noLoc (ident l) [] (UnGuardedRhs rhs) noBinds
  where
    l = f ^. fieldLens
    a = f ^. fieldAccessor

    rhs = mapping (typeOf f) $
        app (app (var "lens") (var a))
            (paren (lamE noLoc [pvar "s", pvar "a"]
                   (RecUpdate (var "s") [FieldUpdate (unqual a) (var "a")])))

dataDecl :: Id -> [QualConDecl] -> [Derive] -> Decl
dataDecl n fs cs = DataDecl noLoc arity [] (ident (n ^. typeId)) [] fs ds
  where
    arity = case fs of
        [QualConDecl _ _ _ (RecDecl _ [_])] -> NewType
        _                                   -> DataType

    ds = map ((,[]) . UnQual . Ident . drop 1 . show) cs

conDecl :: Text -> QualConDecl
conDecl n = QualConDecl noLoc [] [] (ConDecl (ident n) [])

recDecl :: Timestamp -> Id -> [Field] -> QualConDecl
recDecl _  n [] = conDecl (n ^. ctorId)
recDecl ts n fs = QualConDecl noLoc [] [] $
    RecDecl (ident (n ^. ctorId)) (map g fs)
  where
    g f = ([f ^. fieldAccessor . to ident], internal ts f)

requestD :: HasMetadata a f
         => a
         -> HTTP Identity
         -> (Ref, [Inst])
         -> (Ref, [Field])
         -> Decl
requestD m h (a, as) (b, bs) = instD "AWSRequest" (identifier a)
    [ assocTyD (identifier a) "Sv" (m ^. serviceAbbrev)
    , assocTyD (identifier a) "Rs" (b ^. to identifier . typeId)
    , funD "request"  (requestF h as)
    , funD "response" (responseE (m ^. protocol) h b bs)
    ]

responseE :: Protocol -> HTTP Identity -> Ref -> [Field] -> Exp
responseE p h r fs = app (responseF p h r fs) bdy
  where
    n = r ^. to identifier
    s = r ^. refAnn . to extract

    bdy :: Exp
    bdy | null fs    = n ^. ctorId . to var
        | isShared s = lam parseAll
        | otherwise  = lam . ctorE n $ map parseField fs

    lam :: Exp -> Exp
    lam = lamE noLoc [pvar "s", pvar "h", pvar "x"]

    parseField :: Field -> Exp
    parseField x = case x ^. fieldLocation of
        Just Headers        -> parseHeadersE p x
        Just Header         -> parseHeadersE p x
        Just StatusCode     -> app (var "pure") (var "s")
        Just Body    | body -> app (var "pure") (var "x")
        Nothing      | body -> app (var "pure") (var "x")
        _                   -> parseProto x

    parseProto :: Field -> Exp
    parseProto = case p of
        JSON     -> parseJSONE p
        RestJSON -> parseJSONE p
        _        -> parseXMLE  p

    parseAll :: Exp
    parseAll = flip app (var "x") $
        case p of
            JSON     -> var "parseJSON"
            RestJSON -> var "parseJSON"
            _        -> var "parseXML"

    body = any (view fieldStream) fs

instanceD :: Protocol -> Id -> Inst -> Decl
instanceD p n = \case
    FromXML   fs -> fromXMLD   p n fs
    FromJSON  fs -> fromJSOND  p n fs
    ToElement f  -> toElementD p n f
    ToXML     fs -> toXMLD     p n fs
    ToJSON    fs -> toJSOND    p n fs
    ToHeaders es -> toHeadersD p n es
    ToPath    es -> toPathD      n es
    ToQuery   es -> toQueryD   p n es
    ToBody    f  -> toBodyD      n f

fromXMLD, fromJSOND :: Protocol -> Id -> [Field] -> Decl
fromXMLD  p n = decodeD "FromXML"  n "parseXML"  (ctorE n) . map (parseXMLE  p)
fromJSOND p n = decodeD "FromJSON" n "parseJSON" (ctorE n) . map (parseJSONE p)

toElementD :: Protocol -> Id -> Field -> Decl
toElementD p n = instD1 "ToElement" n . funD "toElement" . toElementE p

toXMLD, toJSOND :: Protocol -> Id -> [Field] -> Decl
toXMLD  p n = encodeD "ToXML"  n "toXML"  mconcatE . map (toXMLE p)
toJSOND p n = encodeD "ToJSON" n "toJSON" listE . map (toJSONE p)

toHeadersD :: Protocol -> Id -> [Either (Text, Text) Field] -> Decl
toHeadersD p n = instD1 "ToHeaders" n
    . wildcardD n "toHeaders" (mconcatE . map (toHeadersE p))

toQueryD :: Protocol -> Id -> [Either (Text, Maybe Text) Field] -> Decl
toQueryD p n = instD1 "ToQuery" n
    . wildcardD n "toQuery" (mconcatE . map (toQueryE p))

toPathD :: Id -> [Either Text Field] -> Decl
toPathD n = instD1 "ToPath" n . \case
    [Left t] -> funD "toPath" . app (var "const") $ str t
    es       -> wildcardD n "toPath" (mconcatE . map toPathE) es

toBodyD :: Id -> Field -> Decl
toBodyD n f = instD "ToBody" n [funD "toBody" (toBodyE f)]

instD1 :: Text -> Id -> InstDecl -> Decl
instD1 c n = instD c n . (:[])

instD :: Text -> Id -> [InstDecl] -> Decl
instD c n = InstDecl noLoc Nothing [] [] (unqual c) [n ^. typeId . to tycon]

funD :: Text -> Exp -> InstDecl
funD f = InsDecl . patBind noLoc (pvar f)

funArgsD :: Text -> [Text] -> Exp -> InstDecl
funArgsD f as e = InsDecl $
    sfun noLoc (ident f) (map ident as) (UnGuardedRhs e) noBinds

wildcardD :: Id -> Text -> ([Either a b] -> Exp) -> [Either a b] -> InstDecl
wildcardD n f g = \case
    []                        -> constMemptyD f
    es | not (any isRight es) -> funD f $ app (var "const") (g es)
       | otherwise            -> InsDecl (FunBind [match rec  es])
  where
    match p es = Match noLoc (ident f) [p] Nothing (UnGuardedRhs (g es)) noBinds

    ctor = PApp (n ^. ctorId . to unqual) []
    rec  = PRec (n ^. ctorId . to unqual) [PFieldWildcard]

assocTyD :: Id -> Text -> Text -> InstDecl
assocTyD n x y = InsType noLoc (TyApp (tycon x) (n ^. typeId . to tycon)) (tycon y)

decodeD :: Text -> Id -> Text -> ([a] -> Exp) -> [a] -> Decl
decodeD c n f dec = instD1 c n . \case
    [] -> funD f . app (var "const") $ dec []
    es -> funArgsD f ["x"] (dec es)

encodeD :: Text -> Id -> Text -> ([a] -> Exp) -> [a] -> Decl
encodeD c n f enc = instD c n . (:[]) . \case
    [] -> constMemptyD f
    es -> wildcardD n f (enc . map (either id id)) (map Right es)

constMemptyD :: Text -> InstDecl
constMemptyD f = funArgsD f [] $ app (var "const") (var "mempty")

ctorE :: Id -> [Exp] -> Exp
ctorE n = seqE (n ^. ctorId . to var)

mconcatE :: [Exp] -> Exp
mconcatE = app (var "mconcat") . listE

seqE :: Exp -> [Exp] -> Exp
seqE l []     = app (var "pure") l
seqE l (r:rs) = infixApp l "<$>" (infixE r "<*>" rs)

infixE :: Exp -> QOp -> [Exp] -> Exp
infixE l _ []     = l
infixE l o (r:rs) = infixE (infixApp l o r) o rs

parseXMLE, parseJSONE, parseHeadersE :: Protocol -> Field -> Exp
parseXMLE     = decodeE (Dec ".@" ".@?" ".!@" (var "x") "XML")
parseJSONE    = decodeE (Dec ".:" ".:?" ".!=" (var "x") "JSON")
parseHeadersE = decodeE (Dec ".#" ".#?" ".!#" (var "h") "Headers")

toXMLE, toJSONE :: Protocol -> Field -> Exp
toXMLE  = encodeE (Enc "@=" "XML")
toJSONE = encodeE (Enc ".=" "JSON")

toElementE :: Protocol -> Field -> Exp
toElementE p f = appFun (var "mkElement")
    [ str ns
    , var "."
    , var (f ^. fieldAccessor)
    ]
  where
    ns | Just x <- f ^. fieldNamespace = "{" <> x <> "}" <> n
       | otherwise                      = n

    n = memberName p Input (f ^. fieldId) (f ^. fieldRef)

toHeadersE :: Protocol -> Either (Text, Text) Field -> Exp
toHeadersE p = either pair (encodeE (Enc "=#" "Headers") p)
  where
    pair (k, v) = infixApp (str k) "=#" (impliesE (str v) (var ""))

toQueryE :: Protocol -> Either (Text, Maybe Text) Field -> Exp
toQueryE p = either pair (encodeE (Enc "=:" "Query") p)
  where
    pair (k, Nothing) = str k
    pair (k, Just v)  = infixApp (str k) "=:" (impliesE (str v) (var "ByteString"))

toPathE :: Either Text Field -> Exp
toPathE = either str (app (var "toText") . var . view fieldAccessor)

toBodyE :: Field -> Exp
toBodyE f = var (f ^. fieldAccessor)

impliesE :: Exp -> Exp -> Exp
impliesE x y = paren (infixApp x "::" y)

data Dec = Dec
    { decodeOp      :: QOp
    , decodeMaybeOp :: QOp
    , decodeDefOp   :: QOp
    , decodeVar     :: Exp
    , decodeSuffix  :: Text
    }

decodeE :: Dec -> Protocol -> Field -> Exp
decodeE o p f = case names of
    NMap  mn e k v             -> dec mn (decodeMapF   o) [str e, str k, str v]
    NList mn i
        | TList1 _ <- typeOf f -> dec mn (decodeList1F o) [str i]
        | otherwise            -> dec mn (decodeListF  o) [str i]
    NName (str -> n)
        | f ^. fieldRequired   -> infixApp x (decodeOp o) n
        | otherwise            -> infixApp x (decodeMaybeOp o) n
  where
    names = nestedNames p Output (f ^. fieldId) (f ^. fieldRef)

    dec (Just n) fun xs = decodeMonoidE o n (appFun fun xs)
    dec Nothing  fun xs = appFun fun $ xs ++ [x]

    x = decodeVar o

data Enc = Enc
    { encodeOp     :: QOp
    , encodeSuffix :: Text
    }

encodeE :: Enc -> Protocol -> Field -> Exp
encodeE o p f = case names of
    NMap  mn e k v' -> nest mn $ appFun (encodeMapF o) [str e, str k, str v', v]
    NList mn i      -> nest mn (a i)
    NName n         -> a n
  where
    names = nestedNames p Input (f ^. fieldId) (f ^. fieldRef)

    nest (Just n) = infixApp (str n) (encodeOp o)
    nest Nothing  = id

    a n = infixApp (str n) (encodeOp o) v

    v = var (f ^. fieldAccessor)

maybeStrE :: Maybe Text -> Exp
maybeStrE = maybe (var "Nothing") (paren . app (var "Just") . str)

decodeMonoidE :: Dec -> Text -> Exp -> Exp
decodeMonoidE o n = paren .
    infixApp
        (infixApp
            (infixApp (decodeVar o)
                      (decodeMaybeOp o)
                      (str n))
            (decodeDefOp o)
            (var "mempty"))
        ">>="

decodeMapF, decodeListF, decodeList1F :: Dec -> Exp
decodeMapF   e = var $ "parse" <> decodeSuffix e <> "Map"
decodeListF  e = var $ "parse" <> decodeSuffix e <> "List"
decodeList1F e = var $ "parse" <> decodeSuffix e <> "List1"

encodeMapF :: Enc -> Exp
encodeMapF e = var $ "to" <> encodeSuffix e <> "Map"

-- encodeListF  e = var $ "to" <> encodeSuffix e <> "List"
-- encodeList1F e = var $ "to" <> encodeSuffix e <> "List1"

requestF :: HTTP Identity -> [Inst] -> Exp
requestF h is = var v
  where
    v = mappend (methodToText (h ^. method))
      . fromMaybe mempty
      . listToMaybe
      $ mapMaybe f is

    f = \case
        ToBody    {} -> Just "Body"
        ToJSON    {} -> Just "JSON"
        ToElement {} -> Just "XML"
        _            -> Nothing

-- FIXME: take method into account for responses, such as HEAD etc, particuarly
-- when the body might be totally empty.
responseF :: Protocol -> HTTP Identity -> RefF a -> [Field] -> Exp
responseF p h r fs = wrapper ("receive" <> fun)
  where
    fun | null fs                   = "Null"
        | any (view fieldStream) fs = "Body"
        | otherwise                 = protocolSuffix p

    wrapper v
        | Just x <- r ^. refResultWrapper = app (var (v <> "Wrapper")) (str x)
        | otherwise                       = var v

signature :: Timestamp -> TType -> Type
signature ts = directed False ts Nothing

internal, external :: Timestamp -> Field -> Type
internal ts f = directed True  ts (f ^. fieldDirection) f
external ts f = directed False ts (f ^. fieldDirection) f

directed :: TypeOf a => Bool -> Timestamp -> Maybe Direction -> a -> Type
directed i ts d (typeOf -> t) = case t of
    TType      x _    -> tycon x
    TLit       x      -> literal i ts x
    TNatural          -> tycon nat
    TStream           -> tycon stream
    TSensitive x      -> sensitive (go x)
    TMaybe     x      -> TyApp  (tycon "Maybe")     (go x)
    TList      x      -> TyList (go x)
    TList1     x      -> TyApp  (tycon "NonEmpty")  (go x)
    TMap       k v    -> TyApp  (TyApp (tycon "HashMap") (go k)) (go v)
  where
    go = directed i ts d

    nat | i         = "Nat"
        | otherwise = "Natural"

    sensitive
        | i         = TyApp (tycon "Sensitive")
        | otherwise = id

    stream = case d of
        Nothing     -> "Stream"
        Just Input  -> "RqBody"
        Just Output -> "RsBody"

mapping :: TType -> Exp -> Exp
mapping t e = infixE e "." (go t)
  where
    go = \case
        TSensitive x -> var "_Sensitive" : go x
        TMaybe     x -> coerce (go x)
        x            -> maybeToList (iso x)

    coerce (x:xs) = app (var "mapping") x : xs
    coerce []     = []

iso :: TType -> Maybe Exp
iso = \case
    TLit Time    -> Just (var "_Time")
    TNatural     -> Just (var "_Nat")
    TSensitive _ -> Just (var "_Sensitive")
    _            -> Nothing

literal :: Bool -> Timestamp -> Lit -> Type
literal i ts = tycon . \case
    Int              -> "Int"
    Long             -> "Integer"
    Double           -> "Double"
    Text             -> "Text"
    Blob             -> "Base64"
    Bool             -> "Bool"
    Time | i         -> tsToText ts
         | otherwise -> "UTCTime"

tycon :: Text -> Type
tycon = TyCon . unqual

con :: Text -> Exp
con = Con . unqual

str :: Text -> Exp
str = Exts.Lit . String . Text.unpack

pvar :: Text -> Pat
pvar = Exts.pvar . ident

var :: Text -> Exp
var = Exts.var . ident

-- qop :: Text -> QOp
-- qop = Exts.op . Exts.sym . Text.unpack

param :: Int -> Name
param = Ident . mappend "p" . show

unqual :: Text -> QName
unqual = UnQual . ident

ident :: Text -> Name
ident = Ident . Text.unpack

