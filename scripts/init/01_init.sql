-- Выполняется автоматически при первом запуске контейнера.

-- Схема для сырых данных «как пришли»: грузим сюда CSV без изменений.
CREATE SCHEMA IF NOT EXISTS raw;

-- Схема для вашей модели: таблицы, которые вы спроектируете.
CREATE SCHEMA IF NOT EXISTS core;

-- Схема для витрин и ответов на бизнес-вопросы (при желании).
CREATE SCHEMA IF NOT EXISTS mart;

-- Ищем объекты сначала в core, потом в public.
ALTER DATABASE marketplace SET search_path TO core, public;
