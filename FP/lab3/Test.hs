-- Тести до лабораторної №3. Збірка й запуск (поруч має лежати зібраний lab3 і textbook.txt):
--   ghc -O2 -outputdir build-test -main-is Test Test.hs -o test && ./test
module Test where

import Prelude hiding (Word)

import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import Data.IORef
import Data.List (isInfixOf)
import GHC.IO.Encoding (setFileSystemEncoding, setLocaleEncoding)
import System.Exit (ExitCode (..), exitFailure)
import System.Directory (removeFile)
import System.IO (IOMode (..), hSetEncoding, hSetFileSize, stdout, utf8, withBinaryFile)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

import Main hiding (main)

main :: IO ()
main = do
  setLocaleEncoding utf8 >> setFileSystemEncoding utf8
  hSetEncoding stdout utf8
  failures <- newIORef (0 :: Int)
  let check name ok = do
        putStrLn ((if ok then "  ok   " else "  FAIL ") ++ name)
        unless ok (modifyIORef failures (+ 1))
      eq name expected actual = do
        check name (expected == actual)
        unless (expected == actual) (putStrLn ("       очікувалось " ++ show expected ++ "\n       отримано    " ++ show actual))
      sents = map render . (\(Text ss) -> ss) . parseText
      qws n = questionWords n . parseText
      w = TWord . Word . map Symbol
      p = TPunct . Punct . Symbol
      firstSentence str = case parseText str of Text (x : _) -> x; _ -> Sentence []
      lengths str = [wordLength x | TWord x <- tokenize str]

  putStrLn "Розбір на типи"
  eq "табуляції й пробіли → один пробіл" [w "a", TSpace, w "b", TSpace, w "c"] (tokenize "a\t\t  b \t c")
  eq "порожній рядок → межа абзацу" [w "a", TBreak, w "b"] (tokenize "a\n  \n\tb")
  eq "один перенос рядка — звичайний пробіл" [w "a", TSpace, w "b"] (tokenize "a\r\nb")
  eq "апостроф і дефіс усередині слова" [w "м'який", TSpace, w "будь-який", TSpace, w "п’ять"] (tokenize "м'який будь-який п’ять")
  eq "апостроф/дефіс на краю — розділовий знак" [p '\'', w "a", p '-', TSpace, p '-', w "b"] (tokenize "'a- -b")
  eq "ідентифікатори з _ і цифрами — одне слово" [w "my_var2"] (tokenize "my_var2")
  eq "розділові знаки й оператори" [w "f", p '(', w "x", p ')', p ';'] (tokenize "f(x);")
  eq "текст збирається назад з одним пробілом" "Що це? Так." (render (parseText "Що  це?\tТак."))

  putStrLn "Речення"
  eq "крапки в 3.14, System.out, main.c речення не рвуть" ["Число 3.14 і System.out.println(x) у main.c працюють."]
    (sents "Число 3.14 і System.out.println(x) у main.c працюють.")
  eq "три види кінця речення" ["Так.", "Ні!", "Чому?"] (sents "Так. Ні! Чому?")
  eq "?! ... … і лапки/дужки після знаку" ["Що?!", "Ну...", "Ох…", "Він спитав: «Чому?»", "(Так.)"]
    (sents "Що?! Ну... Ох… Він спитав: «Чому?» (Так.)")
  eq "хвіст без знаку в кінці — теж речення" ["Перше.", "друге без крапки"] (sents "Перше. друге без крапки")
  eq "заголовок без крапки відокремлює порожній рядок" ["Розділ 1", "Що це?"] (sents "Розділ 1\n\nЩо це?")
  eq "речення без слів відкидаються" ["Так."] (sents "... ?! Так.")
  eq "порожній текст" [] (sents "")
  check "питальне: «Чому?»" (isQuestion (Sentence [w "Чому", p '?']))
  check "питальне: «Що?!» і «Що?»»" (all (isQuestion . firstSentence) ["Що?!", "Він: «Що?»", "(Що?)"])
  check "не питальне: «Так.» і «a?b c.»" (not (any (isQuestion . firstSentence) ["Так.", "a?b c.", "?!"]))

  putStrLn "Довжина й відбір слів"
  eq "довжина: апостроф, дефіс не рахуються" [5, 8, 4, 2] (lengths "м'який будь-який п’ять x1")
  eq "довжина: «й» з комбінованою бревою = 1 літера («мий» = 3)" [3] (lengths "мии\x306")
  eq "без повторень, без урахування регістру, у порядку появи" ["Цикл", "коду"] (qws 4 "Цикл чи цикл? ЦИКЛ коду? Цикл. тіло циклу.")
  eq "лише з питальних речень" ["таке"] (qws 4 "Що таке? Тіло буде. Який.")
  eq "числа словами не є" ["x10"] (qws 3 "Що 100 і x10?")
  eq "немає питальних речень" [] (qws 3 "Так. Ні.")
  eq "дуже велика довжина" [] (qws maxBound "Що?")

  putStrLn "Атаки, раунд 1"
  check "«;» у коді — не знак питання (регресія: ASCII ; замість грецького)"
    (not (any (isQuestion . firstSentence) ["Обирають for; у Python.", "for (i = 0; i < n; i++)"]))
  check "повноширинний, арабський, грецький знаки питання, ‽ ⁇ ⁉"
    (all (isQuestion . firstSentence) ["Чому？", "لماذا؟", "Τι\x37E", "Що‽", "Як⁇", "Ну⁉"])
  eq "тернарний оператор a ? b : c не рве речення" ["Вираз a ? b : c обчислюється."] (sents "Вираз a ? b : c обчислюється.")
  eq "старий Mac (\\r\\r), Windows (\\r\\n\\r\\n), U+2029 — межа абзацу" [["Заголовок", "Що?"], ["Заголовок", "Що?"], ["Заголовок", "Що?"]]
    (map sents ["Заголовок\r\rЩо?", "Заголовок\r\n\r\nЩо?", "Заголовок\x2029Що?"])
  eq "U+2028 після ? — межа речення" ["Що?", "Так."] (sents "Що?\x2028Так.")
  eq "«й» складене й розкладене — одне слово" ["Мий"] (qws 3 "Мий? ми\x438\x306? МИЙ?")
  eq "невидимі «літери»-заповнювачі — не слова" [] (qws 1 "Що \x3164 \x2800?")
  eq "м'який перенос і BOM усередині слова не рвуть його" ["програмування"] (qws 13 "Що таке програ\xADмування\xFEFF?")
  let huge = unwords (replicate 30000 "слово") ++ "?\n\nА це що?"
  eq "фрагмент понад 20000 токенів пропускається, наступне речення знаходиться"
    [Nothing, Just "А це що?"] (map (fmap render) (parseFragments huge))

  putStrLn "Безпечний вивід"
  eq "ESC і bidi з файлу не доходять до терміналу" "a\\x1b[2Jb\\x202ec" (safe "a\ESC[2Jb\x202E\&c")

  putStrLn "Програма lab3 цілком"
  let lab args = readProcessWithExitCode ("." </> "lab3") args ""
  (c1, o1, _) <- lab ["textbook.txt", "4"]
  check "приклад: 7 питальних речень, слова довжини 4"
    (c1 == ExitSuccess && "Питальних речень: 7" `isInfixOf` o1 && "таке, цикл, якщо, тіло, буде, Який" `isInfixOf` o1)
  BS.writeFile "t_bad_utf8.txt" (BS.pack [0xD0, 0x9F, 0xFF, 0x3F])
  (c2, _, e2) <- lab ["t_bad_utf8.txt", "3"]
  check "файл не в UTF-8: зрозуміла помилка" (c2 /= ExitSuccess && "UTF-8" `isInfixOf` e2)
  BS.writeFile "t_bom.txt" (BS.pack [0xEF, 0xBB, 0xBF] <> BS.pack [0xD0, 0xA9, 0xD0, 0xBE, 0x3F])   -- BOM + «Що?»
  (c3, o3, _) <- lab ["t_bom.txt", "2"]
  check "BOM з Блокнота не заважає" (c3 == ExitSuccess && "\nЩо\n" `isInfixOf` o3)
  writeFile "t_empty.txt" ""
  (c4, o4, _) <- lab ["t_empty.txt", "3"]
  check "порожній файл" (c4 == ExitSuccess && "Питальних речень: 0" `isInfixOf` o4 && "немає" `isInfixOf` o4)
  withBinaryFile "t_huge.txt" WriteMode (`hSetFileSize` (17 * 1024 * 1024))
  (c7, _, e7) <- lab ["t_huge.txt", "3"]
  removeFile "t_huge.txt"
  check "файл понад 16 МБ відхилено (без читання всього в пам'ять)" (c7 /= ExitSuccess && "16 МБ" `isInfixOf` e7)
  writeFile "t_long.txt" (unwords (replicate 30000 "слово") ++ "?\n\nА це що?")
  (c8, o8, _) <- lab ["t_long.txt", "2"]
  check "попередження про пропущений довгий фрагмент" (c8 == ExitSuccess && "пропущено" `isInfixOf` o8 && "1. А це що?" `isInfixOf` o8)
  (c5, _, e5) <- lab ["немає_такого.txt", "3"]
  check "файл не існує" (c5 /= ExitSuccess && "не вдалося прочитати" `isInfixOf` e5)
  (c6, _, e6) <- lab [".", "3"]
  check "каталог замість файлу" (c6 /= ExitSuccess && "не вдалося прочитати" `isInfixOf` e6)
  forM_ [[], ["textbook.txt"], ["textbook.txt", "0"], ["textbook.txt", "-1"], ["textbook.txt", "abc"]
        , ["textbook.txt", "99999999999999999999"], ["--help", "3"], ["a", "b", "c"]] $ \args -> do
    (c, _, e) <- lab args
    check ("некоректні аргументи " ++ show args ++ " → підказка") (c /= ExitSuccess && "Використання" `isInfixOf` e)

  k <- readIORef failures
  putStrLn (if k == 0 then "Усі тести пройдено." else "Провалено тестів: " ++ show k)
  unless (k == 0) exitFailure
