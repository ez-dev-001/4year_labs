-- Лабораторна робота №1, варіант 4: «Інформаційні сервіси мережі факультету»
-- Запуск: mysql -u root -p < schema.sql
SET NAMES utf8mb4;
DROP DATABASE IF EXISTS faculty_services;
CREATE DATABASE faculty_services CHARACTER SET utf8mb4;
USE faculty_services;

-- Назви й логіни мають містити хоча б одну літеру чи цифру: лише пробіли, табуляції,
-- нерозривні пробіли чи BOM не проходять.

-- 1. Види сервісів
CREATE TABLE service_types (
  id   INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL CHECK (name REGEXP '[\\p{L}\\p{N}]')
);

-- 2. Автори (розробники) сервісів
CREATE TABLE authors (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  full_name VARCHAR(150) NOT NULL CHECK (full_name REGEXP '[\\p{L}\\p{N}]'),
  position  VARCHAR(100) NOT NULL,
  email     VARCHAR(100) NOT NULL
);

-- 3. Сервіси: назва, автор, анотація, вид, версія, умови, кінцевий термін, правила
CREATE TABLE services (
  id               INT AUTO_INCREMENT PRIMARY KEY,
  name             VARCHAR(150) NOT NULL CHECK (name REGEXP '[\\p{L}\\p{N}]'),
  author_id        INT NOT NULL,
  type_id          INT NOT NULL,
  version          VARCHAR(30)  NOT NULL,
  annotation       TEXT         NOT NULL,
  usage_conditions VARCHAR(255) NOT NULL,
  end_date         DATE         NOT NULL,
  rules            TEXT         NOT NULL,
  FOREIGN KEY (author_id) REFERENCES authors(id),
  FOREIGN KEY (type_id)   REFERENCES service_types(id)
);

-- 4. Користувачі
CREATE TABLE users (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  login      VARCHAR(50)  NOT NULL UNIQUE CHECK (login REGEXP '[\\p{L}\\p{N}]'),
  full_name  VARCHAR(150) NOT NULL,
  email      VARCHAR(100) NOT NULL,
  user_group VARCHAR(30)  NOT NULL
);

-- 5. Реєстрація користувачів у сервісах
CREATE TABLE registrations (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  user_id    INT  NOT NULL,
  service_id INT  NOT NULL,
  reg_date   DATE NOT NULL,
  purpose    VARCHAR(255) NOT NULL,
  UNIQUE (user_id, service_id),            -- одна реєстрація користувача в сервісі
  FOREIGN KEY (user_id)    REFERENCES users(id),
  FOREIGN KEY (service_id) REFERENCES services(id)
);

-- 6. Статистика використання (сеанси)
CREATE TABLE usage_stats (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  service_id INT  NOT NULL,
  user_id    INT  NOT NULL,
  used_on    DATE NOT NULL,
  minutes    INT  NOT NULL CHECK (minutes >= 0),
  FOREIGN KEY (service_id) REFERENCES services(id),
  FOREIGN KEY (user_id)    REFERENCES users(id)
);

-- Тестові дані
INSERT INTO service_types (name) VALUES
  ('Навчальна платформа'), ('Хмарне сховище'), ('Обчислювальний сервер'), ('Пошта');

INSERT INTO authors (full_name, position, email) VALUES
  ('Петренко Олег Іванович', 'Адміністратор мережі', 'petrenko@knu.ua'),
  ('Коваль Ірина Миколаївна', 'Доцент кафедри ІПС', 'koval@knu.ua'),
  ('Шевчук Андрій Петрович', 'Інженер', 'shevchuk@knu.ua');

INSERT INTO services (name, author_id, type_id, version, annotation, usage_conditions, end_date, rules) VALUES
  ('Moodle факультету', 2, 1, '4.3', 'Дистанційні курси, тести та завдання', 'Для студентів і викладачів', '2027-06-30', 'Один акаунт на особу'),
  ('Файлове сховище', 1, 2, '2.1', 'Зберігання навчальних матеріалів, 10 ГБ', 'Після реєстрації', '2027-12-31', 'Заборонено зберігати піратський контент'),
  ('GPU-сервер', 3, 3, '1.0', 'Обчислення для дипломних робіт', 'За заявкою керівника', '2026-12-31', 'Не більше 8 годин на добу'),
  ('Пошта @fcs', 1, 4, '3.5', 'Корпоративна пошта факультету', 'Усі співробітники і студенти', '2028-01-01', 'Без спаму');

INSERT INTO users (login, full_name, email, user_group) VALUES
  ('ivanov', 'Іванов Петро', 'ivanov@stud.knu.ua', 'ІПС-41'),
  ('sydorenko', 'Сидоренко Марія', 'sydorenko@stud.knu.ua', 'ІПС-42'),
  ('melnyk', 'Мельник Олена', 'melnyk@knu.ua', 'викладач');

INSERT INTO registrations (user_id, service_id, reg_date, purpose) VALUES
  (1, 1, '2026-09-01', 'Навчання'), (1, 3, '2026-10-02', 'Дипломна робота'),
  (2, 1, '2026-09-01', 'Навчання'), (2, 2, '2026-09-15', 'Матеріали курсу'),
  (3, 1, '2026-08-25', 'Викладання'), (3, 4, '2026-08-25', 'Листування');

INSERT INTO usage_stats (service_id, user_id, used_on, minutes) VALUES
  (1, 1, '2026-10-01', 45), (1, 2, '2026-10-01', 60), (1, 3, '2026-10-02', 90),
  (3, 1, '2026-10-05', 240), (2, 2, '2026-10-06', 15), (4, 3, '2026-10-07', 20);
