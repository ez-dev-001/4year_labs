{-# LANGUAGE ExistentialQuantification #-}
-- Лабораторна робота №1, варіант 4: інформаційна система
-- «Інформаційні сервіси мережі факультету» (Haskell + MySQL).
-- З базою працює через консольний клієнт mysql, тому потрібні лише base і process.
module Main where

import Control.Exception (IOException, try)
import Data.Char (GeneralCategory (..), generalCategory, isControl, isSpace, ord)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Proxy (Proxy (..))
import GHC.IO.Encoding (setLocaleEncoding)
import System.Directory (findExecutablesInDirectories)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitSuccess)
import System.FilePath (getSearchPath, isAbsolute)
import System.IO
import System.Info (os)
import System.Process (readProcessWithExitCode)
import Numeric (showHex)
import Text.Read (readMaybe)

-- Підключення до MySQL: вкажіть свій логін і пароль.
dbConn :: [String]
dbConn = ["--user=root", "--password=root", "--default-character-set=utf8mb4", "--batch", "--skip-column-names"]

-- Ім'я БД; змінна LAB1_DB потрібна тестам, щоб не чіпати робочу базу.
dbName :: IO String
dbName = fromMaybe "faculty_services" <$> lookupEnv "LAB1_DB"

-- Режим сесії задаємо самі: строгі типи й дати замість тихих нулів, і без
-- NO_BACKSLASH_ESCAPES, бо на екрануванні через \ тримається quote.
sessionMode :: String
sessionMode = "SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE';\n"

------------------------------------------------------------------------------
-- Клас «таблиця БД» та його екземпляри

class Table a where
  tableName :: Proxy a -> String
  columns   :: Proxy a -> [String]   -- стовпці без id
  fromRow   :: [String] -> a         -- рядок вибірки: id, потім columns
  toRow     :: a -> [String]         -- зворотне до fromRow, для виводу

data ServiceType = ServiceType { stId :: Int, stName :: String }

data Author = Author
  { auId :: Int, auName :: String, auPosition :: String, auEmail :: String }

data Service = Service
  { svId :: Int, svName :: String, svAuthor :: Int, svType :: Int, svVersion :: String
  , svAnnotation :: String, svConditions :: String, svEndDate :: String, svRules :: String }

data User = User
  { usId :: Int, usLogin :: String, usName :: String, usEmail :: String, usGroup :: String }

data Registration = Registration
  { rgId :: Int, rgUser :: Int, rgService :: Int, rgDate :: String, rgPurpose :: String }

data Usage = Usage
  { ugId :: Int, ugService :: Int, ugUser :: Int, ugDate :: String, ugMinutes :: Int }

instance Table ServiceType where
  tableName _ = "service_types"
  columns _ = ["name"]
  fromRow [i, n] = ServiceType (read i) n
  fromRow r = badRow r
  toRow (ServiceType i n) = [show i, n]

instance Table Author where
  tableName _ = "authors"
  columns _ = ["full_name", "position", "email"]
  fromRow [i, n, p, e] = Author (read i) n p e
  fromRow r = badRow r
  toRow (Author i n p e) = [show i, n, p, e]

instance Table Service where
  tableName _ = "services"
  columns _ = ["name", "author_id", "type_id", "version", "annotation", "usage_conditions", "end_date", "rules"]
  fromRow [i, n, a, t, v, an, c, d, r] = Service (read i) n (read a) (read t) v an c d r
  fromRow r = badRow r
  toRow (Service i n a t v an c d r) = [show i, n, show a, show t, v, an, c, d, r]

instance Table User where
  tableName _ = "users"
  columns _ = ["login", "full_name", "email", "user_group"]
  fromRow [i, l, n, e, g] = User (read i) l n e g
  fromRow r = badRow r
  toRow (User i l n e g) = [show i, l, n, e, g]

instance Table Registration where
  tableName _ = "registrations"
  columns _ = ["user_id", "service_id", "reg_date", "purpose"]
  fromRow [i, u, s, d, p] = Registration (read i) (read u) (read s) d p
  fromRow r = badRow r
  toRow (Registration i u s d p) = [show i, show u, show s, d, p]

instance Table Usage where
  tableName _ = "usage_stats"
  columns _ = ["service_id", "user_id", "used_on", "minutes"]
  fromRow [i, s, u, d, m] = Usage (read i) (read s) (read u) d (read m)
  fromRow r = badRow r
  toRow (Usage i s u d m) = [show i, show s, show u, d, show m]

badRow :: [String] -> a
badRow r = error ("Неочікуваний рядок БД: " ++ show r)

-- Будь-яка таблиця, щоб тримати їх в одному списку меню.
data AnyTable = forall a. Table a => AnyTable (Proxy a)

tables :: [AnyTable]
tables =
  [ AnyTable (Proxy :: Proxy ServiceType), AnyTable (Proxy :: Proxy Author)
  , AnyTable (Proxy :: Proxy Service),     AnyTable (Proxy :: Proxy User)
  , AnyTable (Proxy :: Proxy Registration), AnyTable (Proxy :: Proxy Usage) ]

------------------------------------------------------------------------------
-- Робота з MySQL

-- Клієнт mysql шукаємо лише в абсолютних каталогах PATH. Інакше Windows спершу шукає
-- mysql.exe поруч із програмою та в поточному каталозі, і підкладений файл запуститься замість клієнта.
findMysql :: IO (Maybe FilePath)
findMysql = do
  dirs <- filter isAbsolute <$> getSearchPath
  listToMaybe <$> findExecutablesInDirectories dirs "mysql"

-- Запит іде через stdin: без ліміту довжини командного рядка і без NUL в аргументах.
-- Ім'я БД — через --database=, щоб значення на зразок "--init-command=..." не стало опцією.
runSql :: String -> IO (Maybe [[String]])
runSql q = do
  db <- dbName
  exe <- findMysql
  case exe of
    Nothing -> putStrLn "Не вдалося запустити mysql: клієнт не знайдено в PATH." >> pure Nothing
    Just e -> do
      r <- try (readProcessWithExitCode e (dbConn ++ ["--database=" ++ db]) (sessionMode ++ q))
      case r of
        Left err -> putStrLn ("Не вдалося запустити mysql: " ++ show (err :: IOException)) >> pure Nothing
        Right (ExitSuccess, out, _) -> pure (Just (map parseRow (lines out)))
        Right (_, _, err) -> putStr ("Помилка MySQL: " ++ unlines (map safe (lines err))) >> pure Nothing

-- Рядок виводу --batch: поля через табуляцію, \t \n \\ \0 усередині полів екрановані.
-- shortcut: \r mysql не екранує, тож у Windows \r у кінці рядка вважаємо переводом рядка
-- (значення, що закінчується на \r, там втратить його); на інших ОС рядок не чіпаємо.
parseRow :: String -> [String]
parseRow = map unescape . splitTab . dropCR
  where dropCR s = if os == "mingw32" && not (null s) && last s == '\r' then init s else s

splitTab :: String -> [String]
splitTab s = case break (== '\t') s of
  (a, _ : rest) -> a : splitTab rest
  (a, [])       -> [a]

unescape :: String -> String
unescape ('\\' : c : r) = fromMaybe c (lookup c [('n', '\n'), ('t', '\t'), ('0', '\0'), ('r', '\r')]) : unescape r
unescape (c : r) = c : unescape r
unescape [] = []

-- Екранування введених значень (захист від SQL-ін'єкцій). Запит завжди лишається одним рядком.
quote :: String -> String
quote s = "'" ++ concatMap esc s ++ "'"
  where esc c = maybe [c] (\e -> ['\\', e]) (lookup c specials)
        specials = [('\'', '\''), ('\\', '\\'), ('\n', 'n'), ('\r', 'r'), ('\t', 't'), ('\0', '0'), ('\26', 'Z')]

-- Пошук підрядка: % і _ від користувача — звичайні символи, а не шаблони LIKE.
likePattern :: String -> String
likePattern w = quote ("%" ++ concatMap esc w ++ "%")
  where esc c = if c `elem` "%_\\" then ['\\', c] else [c]

-- Виконує зміну й повертає кількість змінених записів (Nothing — помилка).
exec :: String -> IO (Maybe Int)
exec q = do
  r <- runSql (q ++ ";\nSELECT ROW_COUNT();")
  pure $ case r of
    Just [[n]] -> readMaybe n
    _          -> Nothing

selectAll :: Table a => Proxy a -> IO [a]
selectAll p = maybe [] (map fromRow) <$> runSql
  ("SELECT " ++ intercalate ", " ("id" : columns p) ++ " FROM " ++ tableName p ++ " ORDER BY id")

insertRow :: Table a => Proxy a -> [String] -> IO (Maybe Int)
insertRow p vs = exec
  ("INSERT INTO " ++ tableName p ++ " (" ++ intercalate ", " (columns p) ++ ") VALUES ("
   ++ intercalate ", " (map quote vs) ++ ")")

updateRow :: Table a => Proxy a -> Int -> [String] -> IO (Maybe Int)
updateRow p i vs = exec
  ("UPDATE " ++ tableName p ++ " SET "
   ++ intercalate ", " (zipWith (\c v -> c ++ " = " ++ quote v) (columns p) vs)
   ++ " WHERE id = " ++ show i)

deleteRow :: Table a => Proxy a -> Int -> IO (Maybe Int)
deleteRow p i = exec ("DELETE FROM " ++ tableName p ++ " WHERE id = " ++ show i)

findServices :: String -> IO (Maybe [[String]])
findServices w = runSql
  ("SELECT s.id, s.name, t.name, a.full_name, s.version, s.end_date FROM services s"
   ++ " JOIN service_types t ON t.id = s.type_id JOIN authors a ON a.id = s.author_id"
   ++ " WHERE s.name LIKE " ++ likePattern w ++ " OR s.annotation LIKE " ++ likePattern w
   ++ " ORDER BY s.id")

usageStats :: IO (Maybe [[String]])
usageStats = runSql
  ("SELECT s.name,"
   ++ " (SELECT COUNT(*) FROM registrations r WHERE r.service_id = s.id),"
   ++ " (SELECT COUNT(*) FROM usage_stats u WHERE u.service_id = s.id),"
   ++ " (SELECT COALESCE(SUM(minutes), 0) FROM usage_stats u WHERE u.service_id = s.id) AS total"
   ++ " FROM services s ORDER BY total DESC, s.id")

------------------------------------------------------------------------------
-- Діалоги

-- Дані з БД показуємо безпечно: керуючі символи (ESC-послідовності, переноси рядка) та невидимі
-- символи формату (перемикачі напрямку тексту, BOM, нульової ширини) не доходять до терміналу.
safe :: String -> String
safe = concatMap (\c -> if hidden c then "\\x" ++ showHex (ord c) "" else [c])
  where hidden c = isControl c || generalCategory c `elem` [Format, LineSeparator, ParagraphSeparator]

report :: Maybe Int -> IO ()
report = mapM_ (\n -> putStrLn (if n == 0 then "Запис не знайдено або не змінено." else "Змінено записів: " ++ show n))

printRows :: [String] -> Maybe [[String]] -> IO ()
printRows hdr = mapM_ (putStrLn . intercalate " | " . map safe) . maybe [] (hdr :)

-- Кінець вводу (Ctrl+Z / Ctrl+D) — коректний вихід. Невалідний UTF-8 приходить
-- як сурогати U+DC80..U+DCFF (кодування //ROUNDTRIP), і такий ввід просимо повторити.
ask :: String -> IO String
ask msg = do
  putStr (msg ++ ": ") >> hFlush stdout
  eof <- isEOF
  if eof then putStrLn "\nКінець вводу." >> exitSuccess else do
    s <- getLine
    if any (\c -> c >= '\xDC80' && c <= '\xDCFF') s
      then putStrLn "Некоректне кодування вводу (у Windows виконайте chcp 65001)." >> ask msg
      else pure s

-- Додатне число в межах Int (без тихого переповнення).
parseId :: String -> Maybe Int
parseId s = do
  n <- readMaybe s :: Maybe Integer
  if n >= 1 && n <= toInteger (maxBound :: Int) then Just (fromInteger n) else Nothing

askId :: String -> IO Int
askId msg = ask msg >>= maybe (putStrLn "Введіть додатне ціле число." >> askId msg) pure . parseId

chooseTable :: IO AnyTable
chooseTable = do
  mapM_ (\(n, AnyTable p) -> putStrLn ("  " ++ show n ++ ". " ++ tableName p)) (zip [1 :: Int ..] tables)
  n <- askId "Таблиця"
  if n <= length tables then pure (tables !! (n - 1)) else chooseTable

addDialog :: Table a => Proxy a -> IO ()
addDialog p = mapM ask (columns p) >>= insertRow p >>= report

-- Порожнє введення залишає попереднє значення поля.
editDialog :: Table a => Proxy a -> IO ()
editDialog p = do
  i <- askId "id запису"
  old <- runSql ("SELECT " ++ intercalate ", " (columns p) ++ " FROM " ++ tableName p ++ " WHERE id = " ++ show i)
  case old of
    Just [row] -> do
      new <- mapM (\(c, o) -> (\v -> if null v then o else v) <$> ask (c ++ " [" ++ safe o ++ "]"))
                  (zip (columns p) row)
      updateRow p i new >>= report
    Just _ -> putStrLn "Запис не знайдено."
    Nothing -> pure ()

menu :: IO ()
menu = do
  putStrLn "\n=== Інформаційні сервіси мережі факультету ==="
  putStrLn "1. Переглянути таблицю\n2. Додати запис\n3. Змінити запис\n4. Видалити запис"
  putStrLn "5. Пошук сервісу\n6. Статистика використання\n0. Вихід"
  c <- filter (not . isSpace) <$> ask "Ваш вибір"
  case c of
    "1" -> chooseTable >>= \(AnyTable p) -> selectAll p >>= mapM_ (putStrLn . intercalate " | " . map safe . toRow)
    "2" -> chooseTable >>= \(AnyTable p) -> addDialog p
    "3" -> chooseTable >>= \(AnyTable p) -> editDialog p
    "4" -> chooseTable >>= \(AnyTable p) -> askId "id запису" >>= deleteRow p >>= report
    "5" -> ask "Слово для пошуку (назва або анотація)" >>= findServices
             >>= printRows ["id", "назва", "вид", "автор", "версія", "діє до"]
    "6" -> usageStats >>= printRows ["сервіс", "зареєстровано", "сеансів", "хвилин"]
    "0" -> pure ()
    _   -> putStrLn "Невідомий пункт."
  if c == "0" then putStrLn "До побачення!" else menu

main :: IO ()
main = do
  setLocaleEncoding utf8                         -- обмін з mysql у UTF-8
  mapM_ (`hSetEncoding` utf8) [stdout, stderr]
  hSetEncoding stdin =<< mkTextEncoding "UTF-8//ROUNDTRIP"
  hSetNewlineMode stdin universalNewlineMode     -- CRLF з файлу/Windows не потрапляє в дані
  menu
