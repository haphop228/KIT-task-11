#!/bin/bash

# Скрипт-обертка для управления запуском проекта.
# Принимает опциональный флаг 'profile'.

# Проверяем первый аргумент, переданный скрипту
if [ "$1" == "profile" ]; then
  # --- РЕЖИМ ПРОФИЛИРОВАНИЯ ---
  echo "🚀 Запуск в режиме ПРОФИЛИРОВАНИЯ..."
  # Используем флаг -f, чтобы явно указать Docker Compose, какие файлы использовать.
  # Он "наложит" profiling.override.yml поверх docker-compose.yml.
  docker-compose -f docker-compose.yml -f profiling.override.yml up --build

else
  # --- ОБЫЧНЫЙ РЕЖИМ ---
  echo "🚀 Запуск в ОБЫЧНОМ режиме..."
  docker-compose up -d --build
fi