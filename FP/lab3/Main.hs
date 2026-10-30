{-# OPTIONS_GHC -fno-full-laziness -fno-cse #-}
-- Лабораторна робота №3, варіант 4: у всіх питальних реченнях тексту знайти й надрукувати
-- без повторень слова заданої довжини. Текст підручника з програмування читається з файлу.
-- Збірка: ghc -O2 Main.hs -o lab3      Запуск: lab3 ФАЙЛ ДОВЖИНА
module Main where

import Prelude hiding (Word)

import Control.Exception (IOException, try)
import Control.Monad (when)
import qualified Data.ByteString as BS
import Data.Char (GeneralCategory (..), generalCategory, isAlphaNum, isControl, isLetter, isMark, isSpace, ord, toLower)
import Data.List (mapAccumL)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO
import Text.Read (readMaybe)

------------------------------------------------------------------------------
-- Типи: символ, слово, розділовий знак, речення, текст

newtype Symbol = Symbol Char deriving (Eq, Show)

newtype Word = Word [Symbol] deriving (Eq, Show)

-- Розділовий знак та інші символи, що не належать словам (дужки, оператори, лапки…).
newtype Punct = Punct Symbol deriving (Eq, Show)

-- Пробіл зберігається один: табуляції й послідовності пробілів згортаються при розборі.
-- TBreak — порожній рядок (межа абзацу): заголовок без крапки не зливається з наступним реченням.
data Token = TWord Word | TPunct Punct | TSpace | TBreak deriving (Eq, Show)

newtype Sentence = Sentence [Token] deriving (Eq, Show)

newtype Text = Text [Sentence] deriving (Eq, Show)

class Render a where
  render :: a -> String

instance Render Symbol where render (Symbol c) = [c]
instance Render Word where render (Word s) = concatMap render s
instance Render Punct where render (Punct s) = render s
instance Render Token where
  render (TWord w) = render w
  render (TPunct p) = render p
  render TSpace = " "
  render TBreak = " "
instance Render Sentence where render (Sentence ts) = concatMap render ts
instance Render Text where render (Text ss) = unwords (map render ss)

------------------------------------------------------------------------------
-- Розбір

-- Слово: літери, цифри, '_' (ідентифікатори в коді) і діакритика; апостроф чи дефіс
-- усередині («м'який», «будь-який») слово не розривають.
isWordChar :: Char -> Bool
isWordChar c = (isAlphaNum c || c == '_' || isMark c) && c `notElem` fillers

-- Невидимі «літери»-заповнювачі (хангиль, шрифт Брайля): слово з них виглядало б порожнім.
fillers :: String
fillers = "\x115F\x1160\x3164\xFFA0\x2800"

isJoiner :: Char -> Bool
isJoiner c = c `elem` "'’ʼ-‐‑"

tokenize :: String -> [Token]
tokenize [] = []
tokenize s@(c : rest)
  | isSpace c = let (ws, rest') = span isSpace s
                in (if length (filter (== '\n') ws) >= 2 then TBreak else TSpace) : tokenize rest'
  | isWordChar c = let (w, rest') = spanWord s in TWord (Word (map Symbol w)) : tokenize rest'
  | otherwise = TPunct (Punct (Symbol c)) : tokenize rest
  where
    spanWord xs = case span isWordChar xs of
      (w, j : y : more) | isJoiner j && isWordChar y -> let (w', r) = spanWord (y : more) in (w ++ j : w', r)
      r -> r

-- Знак питання в різних системах письма й варіантах: звичайний, повноширинний, арабський,
-- грецький, ‽ ⁇ ⁈ ⁉.
questionMarks :: String
questionMarks = "?？؟\x37E‽⁇⁈⁉﹖"   -- \x37E — грецький знак питання, не ASCII ";"

isTerminator, isCloser, isQuestionMark :: Token -> Bool
isTerminator t = t `elem` [TPunct (Punct (Symbol c)) | c <- ".!…！．。" ++ questionMarks]
isCloser t = t `elem` [TPunct (Punct (Symbol c)) | c <- ")]}\"'»”’“›"]
isQuestionMark t = t `elem` [TPunct (Punct (Symbol c)) | c <- questionMarks]

-- Речення закінчується групою з . ! ? … (можливо, з дужками чи лапками після неї), яка стоїть
-- впритул до слова і за якою йде пробіл або кінець тексту. Тому крапки в «3.14», «System.out»,
-- «main.c» і тернарний оператор «a ? b : c» речення не рвуть.
-- shortcut: скорочення на зразок «т. д.» теж закінчують речення; для підручника цього досить.
-- Nothing — фрагмент понад maxSentenceTokens токенів без кінця речення (дамп коду чи даних):
-- його пропускаємо до наступної межі, щоб пам'ять не росла з розміром такого фрагмента.
fragments :: [Token] -> [Maybe Sentence]
fragments = go (0 :: Int) []
  where
    go _ acc [] = emit acc []
    go _ acc (TBreak : rest) = emit acc [] ++ go 0 [] rest
    go k acc (t : rest)
      | k >= maxSentenceTokens = Nothing : skip (t : rest)
      | isTerminator t
      , attached acc
      , (tailToks, rest') <- span (\x -> isTerminator x || isCloser x) rest
      , endsHere rest' = emit (t : acc) tailToks ++ go 0 [] rest'
      | otherwise = go (k + 1) (t : acc) rest
    skip [] = []
    skip (TBreak : rest) = go 0 [] rest
    skip (t : rest)
      | isTerminator t, (_, rest') <- span (\x -> isTerminator x || isCloser x) rest, endsHere rest' = go 0 [] rest'
      | otherwise = skip rest
    -- речення без жодного слова («...», «?!») відкидаємо
    emit acc tailToks = [Just (Sentence (trim (reverse acc ++ tailToks))) | any isWordTok acc]
    endsHere r = null r || head r `elem` [TSpace, TBreak]
    attached (x : _) = x `notElem` [TSpace, TBreak]
    attached [] = False
    trim = reverse . dropWhile (== TSpace) . reverse . dropWhile (== TSpace)
    isWordTok (TWord _) = True
    isWordTok _ = False

maxSentenceTokens :: Int
maxSentenceTokens = 20000

sentences :: [Token] -> [Sentence]
sentences = catMaybes . fragments

-- Невидимі м'які переноси (з PDF) і BOM вилучаємо, щоб вони не розривали слова.
parseText :: String -> Text
parseText = Text . catMaybes . parseFragments

parseFragments :: String -> [Maybe Sentence]
parseFragments = fragments . tokenize . normalizeLines . filter (`notElem` "\xAD\xFEFF")

-- Переводи рядка всіх видів (\r\n, \r, NEL, U+2028; U+2029 — межа абзацу) зводимо до \n,
-- щоб порожній рядок у файлі з Windows чи старого Mac теж був межею абзацу.
normalizeLines :: String -> String
normalizeLines ('\r' : '\n' : r) = '\n' : normalizeLines r
normalizeLines (c : r)
  | c `elem` "\r\x85\x2028" = '\n' : normalizeLines r
  | c == '\x2029' = '\n' : '\n' : normalizeLines r
  | otherwise = c : normalizeLines r
normalizeLines [] = []

isQuestion :: Sentence -> Bool
isQuestion (Sentence ts) = any isQuestionMark (takeWhile (\t -> isTerminator t || isCloser t) (reverse ts))

-- Довжина слова — кількість літер і цифр: апостроф, дефіс і діакритика не рахуються.
wordLength :: Word -> Int
wordLength (Word s) = length [c | Symbol c <- s, not (isJoiner c || isMark c)]

-- Слова заданої довжини з питальних речень, без повторень (без урахування регістру),
-- у порядку першої появи. Числа («10», «2026») словами не вважаємо: потрібна хоч одна літера.
questionWords :: Int -> Text -> [String]
questionWords n (Text ss) = concat (snd (mapAccumL (newWords n) Set.empty (filter isQuestion ss)))

-- Слова довжини n з речення, яких ще немає серед seen; повертає й оновлене seen.
-- Ключі зберігаємо як компактний Text: тисячі унікальних слів не роздувають пам'ять.
newWords :: Int -> Set.Set T.Text -> Sentence -> (Set.Set T.Text, [String])
newWords n seen0 (Sentence ts) = go seen0 [render w | TWord w@(Word cs) <- ts, any (\(Symbol c) -> isLetter c) cs, wordLength w == n]
  where
    go seen [] = (seen, [])
    go seen (w : ws)
      | key `Set.member` seen = go seen ws
      | otherwise = let (seen', rest) = go (Set.insert key seen) ws in (seen', w : rest)
      where key = T.pack (wordKey w)

-- Ключ для «без повторень»: регістр не важливий, а «й», «ї», «ё», «ў», набрані літерою з
-- окремою діакритикою, збігаються зі звичайними.
-- shortcut: повна нормалізація Unicode (NFC) потребує окремої бібліотеки; тут лише кирилиця.
wordKey :: String -> String
wordKey = map toLower . compose
  where
    compose (a : m : r) | Just c <- lookup [a, m] table = c : compose r
    compose (a : r) = a : compose r
    compose [] = []
    table = [ ("и\x306", 'й'), ("И\x306", 'Й'), ("і\x308", 'ї'), ("І\x308", 'Ї')
            , ("е\x308", 'ё'), ("Е\x308", 'Ё'), ("у\x306", 'ў'), ("У\x306", 'Ў') ]

------------------------------------------------------------------------------
-- Програма

-- Керуючі й невидимі символи з файлу показуємо як \x.., щоб вони не керували терміналом.
safe :: String -> String
safe = concatMap (\c -> if hidden c then "\\x" ++ showHex (ord c) "" else [c])
  where hidden c = isControl c || c `elem` fillers
                   || generalCategory c `elem` [Format, LineSeparator, ParagraphSeparator, Surrogate]

parsePos :: String -> Maybe Int
parsePos s = do
  n <- if length s <= 30 && all (`elem` "0123456789 ") s then readMaybe s else Nothing :: Maybe Integer
  if n >= 1 && n <= toInteger (maxBound :: Int) then Just (fromInteger n) else Nothing

maxFileBytes :: Int
maxFileBytes = 16 * 1024 * 1024

-- Читаємо не більше 16 МБ (підручник у тексті — кілька МБ; величезний файл чи нескінченний
-- /dev/zero не з'їдять пам'ять)
-- і перевіряємо UTF-8 цілком до обробки, а не падаємо посередині.
readUtf8 :: FilePath -> IO (Either String T.Text)
readUtf8 path = do
  r <- try (withBinaryFile path ReadMode (\h -> BS.hGet h (maxFileBytes + 1)))
  pure $ case r of
    Left e -> Left ("не вдалося прочитати файл: " ++ show (e :: IOException))
    Right bs
      | BS.length bs > maxFileBytes -> Left "файл більший за 16 МБ"
      | otherwise -> either (const (Left "файл не в кодуванні UTF-8 (перезбережіть його як UTF-8)")) Right (TE.decodeUtf8' bs)

-- Два проходи по тексту (він уже в пам'яті як компактний Text): перший друкує питальні
-- речення, другий — нові слова одразу, як знайде. Зберігаються лише ключі знайдених слів.
report :: Int -> T.Text -> IO ()
report n text = do
  (nq, sk) <- questions 0 0 (parseFragments (T.unpack text))
  putStrLn ("Питальних речень: " ++ show nq)
  when (sk > 0) $ putStrLn ("Увага: пропущено фрагментів без кінця речення понад "
                            ++ show maxSentenceTokens ++ " токенів (код чи дані): " ++ show sk)
  putStrLn ("Слова довжини " ++ show n ++ " без повторень:")
  total <- wordsPass 0 Set.empty (filter isQuestion (catMaybes (parseFragments (T.unpack text))))
  putStrLn (if total == 0 then "немає" else "")
  putStrLn ("Усього слів: " ++ show total)
  where
    questions :: Int -> Int -> [Maybe Sentence] -> IO (Int, Int)
    questions nq sk [] = pure (nq, sk)
    questions nq sk (Nothing : ps) = (questions nq $! sk + 1) ps
    questions nq sk (Just q : ps)
      | isQuestion q = putStrLn (show (nq + 1) ++ ". " ++ safe (render q)) >> (questions $! nq + 1) sk ps
      | otherwise = questions nq sk ps
    wordsPass :: Int -> Set.Set T.Text -> [Sentence] -> IO Int
    wordsPass total _ [] = pure total
    wordsPass total seen (q : qs) = do
      let (seen', new) = newWords n seen q
      mapM_ (\(i, w) -> putStr ((if i == 0 then "" else ", ") ++ safe w)) (zip [total ..] new)
      seen' `seq` (wordsPass $! total + length new) seen' qs

usage :: String
usage = "Використання: lab3 ФАЙЛ ДОВЖИНА\n  друкує без повторень слова заданої довжини з усіх питальних речень тексту."

main :: IO ()
main = do
  mapM_ (`hSetEncoding` utf8) [stdout, stderr]
  args <- getArgs
  case args of
    [file, ls] | take 1 file /= "-", Just n <- parsePos ls -> do
      r <- readUtf8 file
      case r of
        Left err -> die ("Помилка: " ++ safe err)
        Right s -> report n s
    _ -> die usage
