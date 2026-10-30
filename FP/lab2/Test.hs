-- Тести до лабораторної №2. Збірка й запуск (поруч має лежати зібраний lab2):
--   ghc -O2 -threaded "-with-rtsopts=-N" -outputdir build-test -main-is Test Test.hs -o test && ./test
module Test where

import Control.Exception (ErrorCall (..), throwIO, try, SomeException)
import Control.Monad (forM, forM_, unless, when)
import Data.Array.IO (IOUArray, getElems, newArray, readArray, writeArray)
import qualified Data.ByteString.Char8 as B
import Data.IORef
import Data.List (isInfixOf)
import GHC.IO.Encoding (setFileSystemEncoding, setLocaleEncoding)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hSetEncoding, stdout, utf8)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcessWithExitCode)

import Main hiding (main)

main :: IO ()
main = do
  setLocaleEncoding utf8 >> setFileSystemEncoding utf8   -- обмін з lab2 у UTF-8
  hSetEncoding stdout utf8
  failures <- newIORef (0 :: Int)
  let check name ok = do
        putStrLn ((if ok then "  ok   " else "  FAIL ") ++ name)
        unless ok (modifyIORef failures (+ 1))
      close eps xs ys = length xs == length ys && and (zipWith (\x y -> abs (x - y) <= eps) xs ys)
      sys rows = (length rows, \i j -> rows !! i !! j)
      solveRows t rows = let (n, el) = sys rows in solve t n el

  putStrLn "parallelFor"
  forM_ [(maxBound, 0, 9), (maxBound, 5, 5), (1, 0, 9), (3, 0, 9), (4, 5, 5), (16, 0, 2), (7, 3, 2), (5, 0, 999), (1000, 0, 999), (3, 990, 999)] $
    \(t, from, to) -> do
      hits <- newArray (0, 999) 0 :: IO (IOUArray Int Int)
      parallelFor t from to (\i -> readArray hits i >>= writeArray hits i . (+ 1))
      hs <- getElems hits
      check ("кожен індекс рівно один раз: потоків " ++ show t ++ ", " ++ show from ++ ".." ++ show to)
        (and [h == (if i >= from && i <= to then 1 else 0) | (i, h) <- zip [0 :: Int ..] hs])
  r <- try (parallelFor 4 0 99 (\i -> when (i == 57) (throwIO (ErrorCall "збій у потоці")))) :: IO (Either SomeException ())
  check "виняток з потоку доходить до викликача (без зависання)" (either (("збій у потоці" `isInfixOf`) . show) (const False) r)

  putStrLn "solve"
  let classic = [[2, 1, -1, 8], [-3, -1, 2, -11], [-2, 1, 2, -3]]
  solveRows 2 classic >>= check "класична система 3×3 → (2, 3, -1)" . maybe False (close 1e-12 [2, 3, -1])
  solveRows 2 [[0, 1, 2], [1, 0, 3]] >>= check "нуль на діагоналі: потрібен вибір головного" . maybe False (close 1e-12 [3, 2])
  solveRows 1 [[5, 10]] >>= check "N = 1" . maybe False (close 0 [2])
  solveRows 3 [[1, 2, 3], [2, 4, 6]] >>= check "залежні рядки → вироджена" . (== Nothing)
  solveRows 3 [[1, 2, 3], [2, 4, 7]] >>= check "несумісна система → вироджена" . (== Nothing)
  solveRows 3 [[0, 0, 1], [0, 0, 1]] >>= check "нульова матриця → вироджена" . (== Nothing)
  solveRows 1 [[0, 1]] >>= check "N = 1, a = 0 → вироджена" . (== Nothing)
  solveRows 50 classic >>= check "потоків більше, ніж рядків" . maybe False (close 1e-12 [2, 3, -1])
  solveRows maxBound classic >>= check "потоків maxBound (раніше переповнення давало хибну відповідь)" . maybe False (close 1e-12 [2, 3, -1])
  solveRows 2 [[1e-200, 1e-200, 2e-200], [1e-200, -1e-200, 0]] >>= check "дуже малі коефіцієнти (масштаб)" . maybe False (close 1e-12 [1, 1])
  let (cn, cel) = sys classic
  check "нев'язка точного розв'язку ≈ 0" (residual cn cel [2, 3, -1] < 1e-12)
  check "нев'язка неправильного розв'язку велика" (residual cn cel [2, 3, 0] > 0.5)
  check "нев'язка біля 1e308 не переповнюється (знайдено фаззингом)"
    (let res = residual 1 (\_ j -> if j == 0 then 3 else 1.7976931348623157e308) [5.9923104495410523e307] in not (isInfinite res || isNaN res))

  let n = 150
  results <- forM [1, 2, 3, 4, 7, 16, 149, 200] $ \t -> solve t n (randomSystem n)
  check "випадкова 150×150: похибка < 1e-9" (all (maybe False (all (\x -> abs (x - 1) < 1e-9))) results)
  check "результат побітово однаковий для 1..200 потоків (немає гонок)" (all (== head results) results)

  putStrLn "parseSystem"
  let ok name s expect = case parseSystem (B.pack s) of
        Right (k, el) -> check name (k == length expect && and [el i j == v | (i, row) <- zip [0 ..] expect, (j, v) <- zip [0 ..] row])
        Left e -> check (name ++ " (" ++ e ++ ")") False
      bad name s needle = case parseSystem (B.pack s) of
        Left e -> check (name ++ " → " ++ e) (needle `isInfixOf` e)
        Right _ -> check (name ++ " (прийнято, а не мало)") False
  ok "звичайний файл" "2\n1 2 3\n4 5 6\n" [[1, 2, 3], [4, 5, 6]]
  ok "CRLF, табуляції, експонента, -0" "2\r\n1e0\t-0 3.5\r\n4 5 -6E-1\r\n" [[1, 0, 3.5], [4, 5, -0.6]]
  ok "UTF-8 BOM з Блокнота" "\xEF\xBB\xBF\&1\n2 4\n" [[2, 4]]
  bad "порожній файл" "  \n" "порожній"
  bad "N = 0" "0" "додатним"
  bad "N < 0" "-2 1 2" "додатним"
  bad "N не число" "abc" "додатним"
  bad "N = 1.5" "1.5 1 2" "додатним"
  bad "N переповнює Int" "99999999999999999999 1 2" "додатним"
  bad "N = maxBound (без переповнення N×(N+1))" "9223372036854775807 1 2" "знайдено 2"
  bad "замало чисел" "2\n1 2 3\n4 5\n" "знайдено 5"
  bad "забагато чисел" "1\n1 2 3" "знайдено 3"
  bad "кома замість крапки" "1\n1,5 2" "\"1,5\""
  bad "NaN" "1\nNaN 2" "NaN"
  bad "Infinity" "1\n1 Infinity" "Infinity"
  bad "1e400 (переповнення)" "1\n1e400 2" "1e400"
  bad "шістнадцяткове 0x1F (синтаксис Haskell)" "1\n0x1F 2" "0x1F"
  bad "вісімкове 0o17" "1\n0o17 2" "0o17"
  bad "дужки (1)" "1\n(1) 2" "(1)"
  bad "N у дужках" "(1) 1 2" "(1)"
  bad "число довше 64 символів" ("1\n1." ++ replicate 70 '0' ++ " 2") "…"
  case parseSystem (B.pack (replicate 1000000 '1' ++ " 1 2")) of
    Left e -> check "N з мільйона цифр: швидка відмова, коротке повідомлення" (length e < 200)
    Right _ -> check "N з мільйона цифр" False
  case parseSystem (B.pack ("1\n" ++ replicate 1000000 '7' ++ " 2")) of
    Left e -> check "коефіцієнт з мільйона цифр: швидка відмова, коротке повідомлення" (length e < 200)
    Right _ -> check "коефіцієнт з мільйона цифр" False

  putStrLn "Програма lab2 цілком"
  let lab args = readProcessWithExitCode ("." </> "lab2") args ""
  writeFile "t_classic.txt" "3\n2 1 -1 8\n-3 -1 2 -11\n-2 1 2 -3\n"
  writeFile "t_singular.txt" "2\n1 2 3\n2 4 6\n"
  writeFile "t_overflow.txt" "2\n1e308 1e308 1e308\n-1e308 1e308 1e308\n"
  writeFile "t_bad.txt" "2\n1 2 3\n"
  (c1, o1, _) <- lab ["t_classic.txt", "3"]
  check "розв'язує файл" (c1 == ExitSuccess && all (`isInfixOf` o1) ["x1 = 2.0", "x2 = 3.0", "x3 = -1.0", "потоків: 3"])
  (c2, _, e2) <- lab ["t_singular.txt"]
  check "вироджена система: код помилки й пояснення" (c2 /= ExitSuccess && "вироджена" `isInfixOf` e2)
  (c3, _, e3) <- lab ["t_overflow.txt"]
  check "переповнення в процесі: код помилки, без NaN у виводі" (c3 /= ExitSuccess && "переповнення" `isInfixOf` e3)
  (c4, _, e4) <- lab ["t_bad.txt"]
  check "некоректний файл" (c4 /= ExitSuccess && "очікувалось" `isInfixOf` e4)
  (c7, o7, _) <- lab ["t_classic.txt", "9223372036854775807"]
  check "lab2 з maxBound потоків: правильна відповідь" (c7 == ExitSuccess && "x3 = -1.0" `isInfixOf` o7)
  (c8, _, e8) <- lab ["."]
  check "каталог замість файлу" (c8 /= ExitSuccess && "не вдалося прочитати" `isInfixOf` e8)
  (c5, _, e5) <- lab ["немає_такого.txt"]
  check "файл не існує" (c5 /= ExitSuccess && "не вдалося прочитати" `isInfixOf` e5)
  forM_ [[], ["t_classic.txt", "0"], ["t_classic.txt", "-1"], ["t_classic.txt", "abc"], ["--bench"], ["--bench", "0"]
        , ["--bench", "5001"], ["--bench", "x"], ["a", "b", "c"], ["--help"]] $ \args -> do
    (c, _, e) <- lab args
    check ("некоректні аргументи " ++ show args ++ " → підказка") (c /= ExitSuccess && "Використання" `isInfixOf` e)
  (c9, _, _) <- lab ["t_classic.txt", "+RTS", "-tpwned_rts", "-RTS"]
  rtsFile <- doesFileExist "pwned_rts"
  check "аргумент +RTS -t<файл> відхилено, файл не створено" (c9 /= ExitSuccess && not rtsFile)
  (c10, _, e10) <- readCreateProcessWithExitCode ((proc ("." </> "lab2") ["t_classic.txt"]) {env = Just [("GHCRTS", "-M1k -tpwned_rts")]}) ""
  rtsFile2 <- doesFileExist "pwned_rts"
  check "GHCRTS не керує рантаймом: відмова, файл не створено" (c10 /= ExitSuccess && "disabled" `isInfixOf` e10 && not rtsFile2)
  (c6, o6, _) <- lab ["--bench", "120"]
  check "--bench 120 працює" (c6 == ExitSuccess && "прискорення" `isInfixOf` o6 && not ("Infinity" `isInfixOf` o6))

  k <- readIORef failures
  putStrLn (if k == 0 then "Усі тести пройдено." else "Провалено тестів: " ++ show k)
  unless (k == 0) exitFailure
