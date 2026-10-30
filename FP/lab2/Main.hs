-- Лабораторна робота №2, варіант 3: розв'язання системи лінійних рівнянь
-- паралельним варіантом методу Гаусса (GHC з ключем -threaded).
-- Збірка: ghc -O2 -threaded "-with-rtsopts=-N" Main.hs -o lab2
-- Без -rtsopts: інакше аргумент "+RTS -t<шлях>" чи змінна GHCRTS керують рантаймом (запис файлів тощо).
module Main where

import Control.Concurrent (forkOn, getNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, throwIO, try)
import Control.Monad (foldM, forM, forM_, when)
import Data.Array.IO (IOUArray, getElems, newListArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftR, xor)
import qualified Data.ByteString.Char8 as B
import Data.List (foldl', nub, sort)
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (IOMode (..), hSetEncoding, stderr, stdout, utf8, withBinaryFile)
import Text.Printf (printf)
import Text.Read (readMaybe)

------------------------------------------------------------------------------
-- Паралельність

-- Ділить індекси from..to на рівні суцільні шматки й обробляє їх у threads потоках,
-- кожен на своєму ядрі. Повертає керування, коли всі закінчили; виняток з потоку
-- передається викликачу, а не губиться.
parallelFor :: Int -> Int -> Int -> (Int -> IO ()) -> IO ()
parallelFor threads from to body = when (from <= to) $ do
  let t = min threads (to - from + 1)        -- зайвих потоків не буває; і без переповнення нижче
      chunk = (to - from + t) `div` t        -- ceil(кількість / t)
  vars <- forM (zip [0 ..] [from, from + chunk .. to]) $ \(core, a) -> do
    v <- newEmptyMVar
    _ <- forkOn core (try (mapM_ body [a .. min to (a + chunk - 1)]) >>= putMVar v)
    pure v
  mapM_ (\v -> takeMVar v >>= either (throwIO :: SomeException -> IO ()) pure) vars

------------------------------------------------------------------------------
-- Метод Гаусса

-- Розв'язує систему n×n методом Гаусса з вибором головного елемента в стовпці.
-- el i j — елемент розширеної матриці (j = n — права частина).
-- Прямий хід паралельний: на кроці k рядки k+1..n-1 незалежні, кожен потік оновлює
-- свої рядки й лише читає рядок k. Зворотний хід послідовний: він O(n²) проти O(n³).
-- Nothing — система вироджена (головний елемент ≤ 1e-12 · max|a_ij|).
solve :: Int -> Int -> (Int -> Int -> Double) -> IO (Maybe [Double])
solve threads n el = do
  let w = n + 1
  a <- newListArray (0, n * w - 1) [el i j | i <- [0 .. n - 1], j <- [0 .. n]] :: IO (IOUArray Int Double)
  let rd i j = readArray a (i * w + j)
      wr i j = writeArray a (i * w + j)
      tol = 1e-12 * maximum (0 : [abs (el i j) | i <- [0 .. n - 1], j <- [0 .. n - 1]])

      step k
        | k == n = Just <$> back
        | otherwise = do
            col <- forM [k .. n - 1] $ \i -> (\v -> (abs v, i)) <$> rd i k
            let (pv, p) = maximum col
            if pv <= tol then pure Nothing else do
              when (p /= k) $ forM_ [k .. n] $ \j -> do
                x <- rd k j
                y <- rd p j
                wr k j y >> wr p j x
              parallelFor threads (k + 1) (n - 1) $ \i -> do
                f <- (/) <$> rd i k <*> rd k k
                forM_ [k + 1 .. n] $ \j -> do
                  akj <- rd k j
                  aij <- rd i j
                  wr i j (aij - f * akj)
              step (k + 1)

      back = do
        x <- newListArray (0, n - 1) (replicate n 0) :: IO (IOUArray Int Double)
        forM_ [n - 1, n - 2 .. 0] $ \i -> do
          rhs <- rd i n
          s <- foldM (\acc j -> do aij <- rd i j; xj <- readArray x j; pure $! acc - aij * xj) rhs [i + 1 .. n - 1]
          aii <- rd i i
          writeArray x i (s / aii)
        getElems x
  step 0

-- max |Ax - b| по вихідній матриці: перевірка, що розв'язок справжній.
-- Рахуємо в масштабі sc = max(1, max|a_ij|), щоб a·x біля 1e308 не переповнювалось у Infinity.
residual :: Int -> (Int -> Int -> Double) -> [Double] -> Double
residual n el xs = sc * maximum (0 : [abs (foldl' (+) 0 (zipWith (\j x -> el i j / sc * x) [0 ..] xs) - el i n / sc) | i <- [0 .. n - 1]])
  where sc = maximum (1 : [abs (el i j) | i <- [0 .. n - 1], j <- [0 .. n]])

finite :: Double -> Bool
finite x = not (isNaN x || isInfinite x)

------------------------------------------------------------------------------
-- Вхідні дані

-- Файл: N, потім N рядків по N+1 чисел (коефіцієнти і права частина).
-- Розбір на ByteString: String з'їдав ~50 байт пам'яті на символ файлу.
parseSystem :: B.ByteString -> Either String (Int, Int -> Int -> Double)
parseSystem s = case B.words (stripBom s) of
  [] -> Left "файл порожній"
  t : rest -> do
    n <- maybe (Left ("N має бути додатним цілим, а не " ++ shown t)) Right (parsePos (B.unpack t))
    let need = toInteger n * (toInteger n + 1)
    when (toInteger (length rest) /= need) $
      Left (printf "очікувалось N×(N+1) = %d чисел, знайдено %d" need (length rest))
    xs <- mapM num rest
    let arr = listArray (0, n * (n + 1) - 1) xs :: UArray Int Double
    Right (n, \i j -> arr ! (i * (n + 1) + j))
  where
    -- Лише десяткові числа до 64 символів: readMaybe сам по собі приймає синтаксис Haskell
    -- (0x1F, 0o17, (1)), а на мільйонах цифр працює секундами.
    num t = case readMaybe (B.unpack t) of
      Just x | B.length t <= 64, B.all (`elem` "0123456789+-.eE") t, finite x -> Right x
      _ -> Left ("некоректне число: " ++ shown t)
    shown t = show (B.unpack (B.take 40 t)) ++ (if B.length t > 40 then "…" else "")
    stripBom x = fromMaybe x (B.stripPrefix (B.pack "\xEF\xBB\xBF") x)   -- BOM з Блокнота

-- Додатне ціле в межах Int (без тихого переповнення).
parsePos :: String -> Maybe Int
parsePos s = do
  n <- if length s <= 30 && all (`elem` "0123456789 ") s then readMaybe s else Nothing :: Maybe Integer
  if n >= 1 && n <= toInteger (maxBound :: Int) then Just (fromInteger n) else Nothing

-- Детермінована псевдовипадкова система з розв'язком x = (1, …, 1): b_i — сума рядка.
randomSystem :: Int -> Int -> Int -> Double
randomSystem n i j
  | j < n = rnd (i * n + j)
  | otherwise = foldl' (+) 0 [rnd (i * n + c) | c <- [0 .. n - 1]]
  where
    rnd k = fromIntegral (mix (fromIntegral k) `shiftR` 11) / 2 ^ (52 :: Int) - 1   -- [-1, 1)
    mix :: Word64 -> Word64   -- splitmix64
    mix z0 = let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
                 z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
             in z2 `xor` (z2 `shiftR` 31)

------------------------------------------------------------------------------
-- Програма

timed :: IO a -> IO (a, Double)
timed act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  pure (r, t1 - t0)

maxFileBytes :: Int
maxFileBytes = 64 * 1024 * 1024

fromFile :: FilePath -> Int -> IO ()
fromFile file threads = do
  -- Читаємо не більше 64 МБ: величезний чи нескінченний файл не з'їсть пам'ять.
  r <- try (withBinaryFile file ReadMode (\h -> B.hGet h (maxFileBytes + 1)))
  case r of
    Left e -> die ("Помилка: не вдалося прочитати файл: " ++ show (e :: IOException))
    Right bytes | B.length bytes > maxFileBytes -> die "Помилка: файл більший за 64 МБ."
    Right bytes -> case parseSystem bytes of
      Left err -> die ("Помилка: " ++ err)
      Right (n, el) -> do
        (res, sec) <- timed (solve threads n el)
        case res of
          Nothing -> die "Помилка: система вироджена (немає єдиного розв'язку)."
          Just xs
            | not (all finite xs) -> die "Помилка: числове переповнення, коефіцієнти завеликі."
            | otherwise -> do
                forM_ (zip [1 :: Int ..] xs) $ \(i, x) -> printf "x%d = %.10g\n" i x
                printf "Нев'язка max|Ax-b| = %.3e; потоків: %d; час: %.4f с\n" (residual n el xs) threads sec

-- Заміри часу на випадковій системі для 1, 2, 4, … потоків (до кількості ядер).
bench :: Int -> Int -> IO ()
bench caps n = do
  printf "Система %d×%d, доступно ядер: %d\n" n n caps
  when (caps == 1) $ putStrLn "Увага: доступне лише 1 ядро, прискорення не буде."
  let run t = do
        (r, sec) <- timed (solve t n (randomSystem n))
        pure (sec, maybe (1 / 0) (maximum . map (abs . subtract 1)) r)
      row :: Int -> Double -> Double -> Double -> IO ()
      row = printf "%7d | %8.3f | %11.2f | %.2e\n"
  putStrLn "потоків |   час, с | прискорення | похибка max|x-1|"
  (base, e1) <- run 1
  row 1 base 1 e1
  forM_ (drop 1 (nub (sort (caps : takeWhile (<= caps) (iterate (* 2) 1))))) $ \t -> do
    (sec, e) <- run t
    row t sec (base / sec) e

usage :: String
usage = unlines
  [ "Використання:"
  , "  lab2 ФАЙЛ [ПОТОКИ]   розв'язати систему з файлу (ПОТОКИ за замовчуванням = кількість ядер)"
  , "  lab2 --bench N       заміри часу на випадковій системі N×N, 1 ≤ N ≤ 5000"
  , "Формат файлу: N, потім N рядків по N+1 чисел (коефіцієнти і права частина)." ]

main :: IO ()
main = do
  mapM_ (`hSetEncoding` utf8) [stdout, stderr]
  caps <- getNumCapabilities
  args <- getArgs
  case args of
    ["--bench", s] | Just n <- parsePos s, n <= 5000 -> bench caps n
    [file] | isFile file -> fromFile file caps
    [file, s] | isFile file, Just t <- parsePos s -> fromFile file t
    _ -> die usage
  where isFile f = take 1 f /= "-"   -- ключ на зразок --bench не плутаємо з ім'ям файлу
