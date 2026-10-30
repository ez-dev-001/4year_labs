-- Тести до лабораторної №1. Працюють з окремою БД faculty_services_test (робочу не чіпають).
-- Збірка й запуск (потрібен MySQL і зібраний lab1, див. README):
--   ghc -outputdir build-test -main-is Test Test.hs -o test && ./test
module Test where

import Control.Exception (finally)
import Control.Monad (forM, forM_, unless, when)
import Data.Bits (shiftR, xor)
import Data.IORef
import Data.List (isInfixOf, isPrefixOf)
import Data.Proxy (Proxy (..), asProxyTypeOf)
import Data.Word (Word64)
import GHC.IO.Encoding (char8, getLocaleEncoding, setLocaleEncoding, utf8)
import System.Directory (doesFileExist, getPermissions, removeFile, setOwnerExecutable, setPermissions)
import System.Environment (getEnv, setEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (searchPathSeparator, (</>))
import System.Info (os)
import System.IO (hSetEncoding, stdout)
import System.Process (readProcessWithExitCode)

import Main hiding (main)

testDb :: String
testDb = "faculty_services_test"

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  setEnv "LAB1_DB" testDb
  failures <- newIORef (0 :: Int)
  let check name ok = do
        putStrLn ((if ok then "  ok   " else "  FAIL ") ++ name)
        unless ok (modifyIORef failures (+ 1))
      eq name expected actual = do
        check name (expected == actual)
        unless (expected == actual) (putStrLn ("       очікувалось " ++ show expected ++ "\n       отримано    " ++ show actual))

  putStrLn "Чисті функції"
  eq "parseRow: таб-роздільник і екранування" ["a\tb", "c\\d\n", "x\0"] (parseRow "a\\tb\tc\\\\d\\n\tx\\0")
  eq "parseRow: \\r у кінці (у Windows — перевод рядка)" ["1", if os == "mingw32" then "abc" else "abc\r"] (parseRow "1\tabc\r")
  eq "parseRow: порожні поля" ["", "", ""] (parseRow "\t\t")
  eq "quote: однорядковий результат" False (any (`elem` "\n\r\0") (quote "a\nb\rc\0d"))
  eq "likePattern: % _ \\ екрановані" "'%a\\\\%b\\\\_c\\\\\\\\%'" (likePattern "a%b_c\\")
  forM_ [("5", Just 5), (" 7 ", Just 7), ("0", Nothing), ("-1", Nothing), ("abc", Nothing), ("", Nothing)
        , ("1.5", Nothing), ("9223372036854775807", Just maxBound)
        , ("9223372036854775808", Nothing), ("18446744073709551617", Nothing)] $ \(s, r) ->
    eq ("parseId " ++ show s) r (parseId s)
  eq "safe: перенос рядка не підробить рядок таблиці" "a\\xa99 | фейк" (safe "a\n99 | фейк")
  eq "safe: ESC-послідовність знешкоджена" "\\x1b[2J\\x1b]52;c;x\\x7" (safe "\ESC[2J\ESC]52;c;x\BEL")
  eq "safe: bidi-перемикач видно" "Moodle\\x202eexe" (safe "Moodle\x202E\&exe")
  eq "safe: BOM і пробіл нульової ширини видно" "a\\xfeffb\\x200bc" (safe "a\xfeff\&b\x200b\&c")
  eq "safe: звичайний текст без змін" "Ї ґ C:\\temp 😀" (safe "Ї ґ C:\\temp 😀")
  let rt p row = toRow (fromRow row `asProxyTypeOf` p) == row
  check "fromRow/toRow: усі 6 екземплярів" $ and
    [ rt (Proxy :: Proxy ServiceType) ["1", "x"]
    , rt (Proxy :: Proxy Author) ["2", "a", "b", "c"]
    , rt (Proxy :: Proxy Service) ["3", "n", "1", "2", "v", "an", "c", "2026-01-01", "r"]
    , rt (Proxy :: Proxy User) ["4", "l", "n", "e", "g"]
    , rt (Proxy :: Proxy Registration) ["5", "1", "2", "2026-01-01", "p"]
    , rt (Proxy :: Proxy Usage) ["6", "1", "2", "2026-01-01", "30"] ]

  putStrLn "Інтеграція з MySQL"
  schema <- readFile "schema.sql"
  (code, _, err) <- readProcessWithExitCode "mysql" dbConn (replace "faculty_services" testDb schema)
  unless (code == ExitSuccess) (putStrLn ("Не вдалося створити тестову БД: " ++ err) >> exitFailure)

  -- Тести тимчасово змінюють глобальний sql_mode; повертаємо саме те значення, що було.
  origMode <- maybe "" (concat . concat) <$> runSql "SELECT @@GLOBAL.sql_mode"
  let restoreMode = runSql ("SET GLOBAL sql_mode = " ++ quote origMode)

  counts <- forM tables (\(AnyTable p) -> length <$> selectAll p)
  eq "кількість записів у 6 таблицях" [4, 3, 4, 3, 6, 6] counts

  let st = Proxy :: Proxy ServiceType
      nasty = [ "'", "\\", "\\'", "''", "' OR '1'='1", "'); DROP TABLE users; -- ", "x\\'); DROP TABLE users; -- "
              , "a\tb", "рядок1\nрядок2", "a\rb", "%_", "nul\0byte", "ctrl\26z", "Ї ґ є 😀", "\\! ls", "\\q"
              , "NULL", "\"", "`", "-- коментар", "/* x */", "delimiter //", "; SELECT 1;", "\ESC[2J"
              , "\\! touch pwned", "x';\nsystem touch pwned\n'" ]
              -- у Windows \r у кінці значення свідомо зрізається (див. parseRow)
              ++ ["кінець\r" | os /= "mingw32"]
  forM_ (map ("a" ++) nasty) $ \s -> do   -- "a": назва мусить містити літеру (CHECK)
    ins <- insertRow st [s]
    back <- map (last . toRow) <$> selectAll st
    check ("зберігається без змін: " ++ show s) (ins == Just 1 && last back == s)
  usersLeft <- length <$> selectAll (Proxy :: Proxy User)
  eq "таблиця users ціла після ін'єкцій" 3 usersLeft

  -- Серверний режим NO_BACKSLASH_ESCAPES ламав екранування: тепер сесія задає режим сама.
  _ <- runSql "SET GLOBAL sql_mode = CONCAT(@@GLOBAL.sql_mode, ',NO_BACKSLASH_ESCAPES')"
  (do ins <- insertRow st ["x\\'); DROP TABLE usage_stats; -- "]
      eq "NO_BACKSLASH_ESCAPES: ін'єкція не спрацьовує" (Just 1) ins
      n <- length <$> selectAll (Proxy :: Proxy Usage)
      eq "NO_BACKSLASH_ESCAPES: usage_stats на місці" 6 n)
    `finally` restoreMode

  -- Нестрогий сервер раніше мовчки писав 0 і 0000-00-00.
  _ <- runSql "SET GLOBAL sql_mode = ''"
  (do let u = Proxy :: Proxy Usage
      forM_ [ ("хвилини 'abc'", ["1", "1", "2026-10-10", "abc"]), ("дата 'abc'", ["1", "1", "abc", "5"])
            , ("дата 2026-02-30", ["1", "1", "2026-02-30", "5"]), ("порожній service_id", ["", "1", "2026-10-10", "5"])
            , ("від'ємні хвилини", ["1", "1", "2026-10-10", "-500"]), ("неіснуючий сервіс", ["999", "1", "2026-10-10", "5"]) ] $
        \(name, row) -> insertRow u row >>= eq ("відхилено: " ++ name) Nothing
      n <- length <$> selectAll u
      eq "у usage_stats нічого зайвого" 6 n)
    `finally` restoreMode

  insertRow (Proxy :: Proxy Registration) ["1", "1", "2026-10-10", "дубль"] >>= eq "відхилено: повторна реєстрація" Nothing
  forM_ [("порожня", ""), ("пробіли", "   "), ("табуляція", "\t"), ("\\r", "\r"), ("нерозривний пробіл", "\xa0")
        , ("BOM", "\xfeff"), ("пробіл нульової ширини", "\x200b"), ("emoji без літер", "😀")] $ \(name, v) ->
    insertRow st [v] >>= eq ("відхилено: назва без літер і цифр (" ++ name ++ ")") Nothing
  insertRow (Proxy :: Proxy Service) ["Довга", "1", "1", "1.0", replicate 20000 'я', "у", "2027-01-01", "п"]
    >>= eq "довге значення (20000 символів) записується" (Just 1)

  deleteRow st 9999 >>= eq "видалення неіснуючого id: 0 записів" (Just 0)
  updateRow st 9999 ["x"] >>= eq "зміна неіснуючого id: 0 записів" (Just 0)
  deleteRow (Proxy :: Proxy Author) 1 >>= eq "видалення автора з сервісами блокує FK" Nothing
  updateRow st 1 ["Нова назва"] >>= eq "зміна запису" (Just 1)
  deleteRow st 5 >>= eq "видалення запису" (Just 1)

  fmap length <$> findServices "%" >>= eq "пошук '%' — літерал, не шаблон" (Just 0)
  fmap length <$> findServices "_" >>= eq "пошук '_' — літерал, не шаблон" (Just 0)
  fmap (map (!! 1)) <$> findServices "MOODLE" >>= eq "пошук без урахування регістру" (Just ["Moodle факультету"])
  fmap length <$> findServices "факультету" >>= eq "пошук у назві та анотації" (Just 2)
  fmap (take 2) <$> usageStats >>= eq "статистика: топ-2"
    (Just [["GPU-сервер", "1", "1", "240"], ["Moodle факультету", "3", "3", "195"]])

  path <- getEnv "PATH"
  setEnv "PATH" "/nonexistent"
  r <- runSql "SELECT 1" `finally` setEnv "PATH" path
  eq "без mysql у PATH: помилка, а не падіння" Nothing r

  -- Ім'я БД з оточення не може стати опцією mysql (--init-command виконав би SQL).
  setEnv "LAB1_DB" ("--init-command=DROP TABLE " ++ testDb ++ ".usage_stats")
  r2 <- runSql "SELECT 1" `finally` setEnv "LAB1_DB" testDb
  n2 <- length <$> selectAll (Proxy :: Proxy Usage)
  check "LAB1_DB=--init-command=… не виконує SQL" (r2 == Nothing && n2 == 6)

  -- Підкладений «mysql» у поточному каталозі (і відносний шлях у PATH) не запускається.
  writeFile "mysql" "#!/bin/sh\ntouch pwned_planted\n"
  writeFile "mysql.exe" "not a real program"
  getPermissions "mysql" >>= setPermissions "mysql" . setOwnerExecutable True
  setEnv "PATH" ("." ++ [searchPathSeparator] ++ path)
  r3 <- runSql "SELECT 7" `finally` (setEnv "PATH" path >> mapM_ removeFile ["mysql", "mysql.exe"])
  planted <- doesFileExist "pwned_planted"
  when planted (removeFile "pwned_planted")
  check "підкладений mysql у поточному каталозі ігнорується" (r3 == Just [["7"]] && not planted)

  -- Фаззинг: випадкові склейки небезпечних фрагментів проходять туди й назад без змін,
  -- у звичайному режимі сервера і з NO_BACKSLASH_ESCAPES.
  let frags = [ "'", "\"", "`", "\\", ";", "#", "-- ", "/*", "*/", "/*!", "\n", "\t", "\0", "\26", "%", "_"
              , "\\!", "\\N", "\\c", "\\G", "\\q", "\\.", "\\'", "''", "N'", "X'27'", "delimiter //\n"
              , "system touch pwned_fuzz", "\\! touch pwned_fuzz;", "a", "я", "😀", "\x7f", "\xa0", "\x2028"
              , "\x85", "\xfeff", "\x202e", "\ESC[0m", "NULL", "\\Z", "\\0", "\\n" ] ++ ["\r" | os /= "mingw32"]
      mixW :: Word64 -> Word64
      mixW z0 = let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
                    z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
                in z2 `xor` (z2 `shiftR` 31)
      pick k = fromIntegral (mixW (fromIntegral k) `mod` fromIntegral (length frags))
      payload k = take 90 ("x" ++ concat [frags !! pick (k * 100 + i) | i <- [0 .. pick k `mod` 12]])
  forM_ [("звичайний", quote origMode), ("NO_BACKSLASH_ESCAPES", "CONCAT(" ++ quote origMode ++ ", ',NO_BACKSLASH_ESCAPES')")] $ \(mode, sqlMode) -> do
    _ <- runSql ("SET GLOBAL sql_mode = " ++ sqlMode)
    bad <- (`finally` restoreMode) $ fmap concat $ forM [1 .. 250 :: Int] $ \k -> do
      let s = payload (k + length mode * 1000)
      ins <- insertRow st [s]
      back <- runSql "SELECT name FROM service_types ORDER BY id DESC LIMIT 1"
      pure [s | ins /= Just 1 || back /= Just [[s]]]
    pwned <- doesFileExist "pwned_fuzz"
    tablesNow <- runSql "SHOW TABLES"
    check ("фаззинг 250 значень, режим " ++ mode ++ ": усе без змін, команди клієнта не виконались, таблиці на місці")
      (null bad && not pwned && fmap length tablesNow == Just 6)
    unless (null bad) (putStrLn ("       розбіжності: " ++ show (take 3 bad)))

  putStrLn "Програма lab1 цілком"
  let runLab input = readProcessWithExitCode ("." </> "lab1") [] input
  (c1, _, _) <- runLab ""
  eq "порожній ввід (EOF одразу)" ExitSuccess c1
  (c2, _, _) <- runLab "2\n1\n"
  eq "EOF посеред діалогу" ExitSuccess c2
  (c3, o3, _) <- runLab "1\n18446744073709551617\n0\n0\n"
  check "переповнення номера таблиці відхилено" (c3 == ExitSuccess && "Введіть додатне ціле число" `isInfixOf` o3)
  (c4, o4, _) <- runLab " 6 \n0\n"
  check "пункт меню з пробілами" (c4 == ExitSuccess && "GPU-сервер" `isInfixOf` o4)
  (c5, o5, _) <- runLab "2\n1\r\nCRLF назва\r\n0\r\n"
  back <- map (last . toRow) <$> selectAll st
  check "CRLF у вводі не потрапляє в дані" (c5 == ExitSuccess && last back == "CRLF назва" && "До побачення" `isInfixOf` o5)
  -- Невалідний UTF-8: шлемо сирі байти через char8.
  enc <- getLocaleEncoding
  setLocaleEncoding char8
  (c6, o6, _) <- runLab "2\n1\n\xff\xfe\n\n" `finally` setLocaleEncoding enc
  check "невалідний UTF-8: повторний запит, без падіння" (c6 == ExitSuccess && "chcp 65001" `isInfixOf` o6)

  _ <- insertRow st ["Справжній\n99 | ФЕЙКОВИЙ ЗАПИС\n\ESC[2J"]
  (c7, o7, _) <- runLab "1\n1\n0\n"
  check "вивід: перенос рядка в даних не створює фейковий рядок, ESC не доходить до терміналу"
    (c7 == ExitSuccess && not (any ("99 | ФЕЙКОВИЙ" `isPrefixOf`) (lines o7)) && '\ESC' `notElem` o7)

  n <- readIORef failures
  putStrLn (if n == 0 then "Усі тести пройдено." else "Провалено тестів: " ++ show n)
  unless (n == 0) exitFailure

replace :: String -> String -> String -> String
replace old new = go
  where go [] = []
        go s@(c : r) | take (length old) s == old = new ++ go (drop (length old) s)
                     | otherwise = c : go r
