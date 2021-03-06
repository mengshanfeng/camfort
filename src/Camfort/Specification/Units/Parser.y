{ -- -*- Mode: Haskell -*-

module Camfort.Specification.Units.Parser
  ( unitParser
  , UnitParseError
  ) where

import Control.Monad.Except (throwError)
import Data.Char (isLetter, isNumber, isAlphaNum, toLower)

import Camfort.Specification.Parser (mkParser, SpecParser)
import Camfort.Specification.Units.Parser.Types

}

%monad { UnitSpecParser } { >>= } { return }
%name parseUnit UNIT
%tokentype { Token }

%token
 unit     { TId "unit" }
 record   { TRecord }
 id       { TId $$ }
 one      { TNum "1" }
 num      { TNum $$ }
 ','      { TComma }
 '-'      { TMinus }
 '*'      { TMult }
 '**'     { TExponentiation }
 '/'      { TDivision }
 '::'     { TDoubleColon }
 '='      { TEqual }
 '('      { TLeftPar }
 ')'      { TRightPar }

%left '*'
%left '/'
%left '**'
%%

UNIT :: { UnitStatement }
: unit UEXP VARIABLE_ANNOTATION { UnitAssignment $3 $2 }
| unit '::' id '=' UEXP { UnitAlias $3 $5 }

VARIABLE_ANNOTATION :: { Maybe [String] }
: '::' IDS { Just $2 }
| {-EMPTY-} { Nothing }

IDS :: { [String] }
: id ',' IDS   { $1 : $3 }
| id           { [$1] }

UEXP :: { UnitOfMeasure }
: UEXP_LEVEL1   { $1 }
| one           { Unitless }
| '(' one ')'   { Unitless }
| '(' ')'       { Unitless }
| record '(' RECORD_DECLS ')' { UnitRecord $3 }

RECORD_DECLS :: { [(String, UnitOfMeasure)] }
: RECORD_DECL ',' RECORD_DECLS { $1 : $3 }
| RECORD_DECL                  { [$1] }

RECORD_DECL :: { (String, UnitOfMeasure) }
: UEXP '::' id { ($3, $1) }

UEXP_LEVEL1 :: { UnitOfMeasure }
: UEXP_LEVEL1 UEXP_LEVEL2             { UnitProduct $1 $2 }
| UEXP_LEVEL1 '*' UEXP_LEVEL2         { UnitProduct $1 $3 }
| UEXP '/' UEXP_LEVEL2                { UnitQuotient $1 $3 }
| UEXP_LEVEL2                         { $1 }

UEXP_LEVEL2 :: { UnitOfMeasure }
: UEXP_LEVEL2 '**' POW                { UnitExponentiation $1 $3 }
| '(' UEXP_LEVEL1 ')'                 { $2 }
| id                                  { UnitBasic $1 }

POW :: { UnitPower }
: SIGNED_NUM                          { UnitPowerInteger $1 }
| '(' SIGNED_NUM ')'                  { UnitPowerInteger $2 }
| '(' SIGNED_NUM '/' SIGNED_NUM ')'   { UnitPowerRational $2 $4 }

SIGNED_NUM :: { Integer }
: NUM       { read $1 }
| '-' NUM   { read $ '-' : $2 }

NUM :: { String }
: num   { $1 }
| one   { "1" }

{

data UnitParseError
  -- | Not a valid identifier character.
  = NotAnIdentifier Char
  -- | Tokens do not represent a syntactically valid specification.
  | CouldNotParseSpecification [Token]
  deriving (Eq)

instance Show UnitParseError where
  show (CouldNotParseSpecification ts) =
    "Could not parse specification at: \"" ++ show ts ++ "\"\n"
  show (NotAnIdentifier c) = "Invalid character in identifier: " ++ show c

notAnIdentifier :: Char -> UnitParseError
notAnIdentifier = NotAnIdentifier

couldNotParseSpecification :: [Token] -> UnitParseError
couldNotParseSpecification = CouldNotParseSpecification

type UnitSpecParser a = Either UnitParseError a

data Token =
   TUnit
 | TComma
 | TDoubleColon
 | TExponentiation
 | TDivision
 | TMinus
 | TMult
 | TEqual
 | TLeftPar
 | TRightPar
 | TRecord
 | TId String
 | TNum String
 deriving (Show, Eq)

addToTokens :: Token -> String -> UnitSpecParser [ Token ]
addToTokens tok rest = do
 tokens <- lexer rest
 return $ tok : tokens

lexer :: String -> UnitSpecParser [ Token ]
lexer [] = Right []
lexer ['\n']  = Right []
lexer ['\r', '\n']  = Right []
lexer ['\r']  = Right [] -- windows
lexer (' ':xs) = lexer xs
lexer ('\t':xs) = lexer xs
lexer (':':':':xs) = addToTokens TDoubleColon xs
lexer ('*':'*':xs) = addToTokens TExponentiation xs
lexer (',':xs) = addToTokens TComma xs
lexer ('/':xs) = addToTokens TDivision xs
lexer ('-':xs) = addToTokens TMinus xs
lexer ('*':xs) = addToTokens TMult xs
lexer ('=':xs) = addToTokens TEqual xs
lexer ('(':xs) = addToTokens TLeftPar xs
lexer (')':xs) = addToTokens TRightPar xs
lexer (x:xs)
 | isLetter x || x == '\'' = aux (\ c -> isAlphaNum c || c `elem` ['\'','_','-'])
                                 (\ s -> if s == "record" then TRecord else TId s)
 | isNumber x              = aux isNumber TNum
 | otherwise
     = throwError $ notAnIdentifier x
 where
   aux p cons =
     let (target, rest) = span p xs
     in lexer rest >>= (\tokens -> return $ cons (x:target) : tokens)

unitParser :: SpecParser UnitParseError UnitStatement
unitParser = mkParser (\src -> do
                          tokens <- lexer $ map toLower src
                          parseUnit tokens) ["unit"]

happyError :: [ Token ] -> UnitSpecParser a
happyError = throwError . couldNotParseSpecification

}
