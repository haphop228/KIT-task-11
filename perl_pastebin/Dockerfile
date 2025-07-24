# Используем официальный, стабильный образ Perl
FROM perl:5.38

# Устанавливаем системные пакеты для компиляции
RUN apt-get update && apt-get install -y \
    build-essential \
    zlib1g-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Устанавливаем cpanminus
RUN curl -L https://cpanmin.us | perl - App::cpanminus

# --- УПРАВЛЕНИЕ КЛЮЧЕВЫМИ ЗАВИСИМОСТЯМИ ---
# Шаг 1: Принудительно обновляем URI, чтобы избежать конфликта версий
RUN cpanm URI

# Шаг 2: Принудительно устанавливаем СОВМЕСТИМУЮ версию JSON::Validator
# Эта версия точно работает с последней версией OpenAPI
RUN cpanm JSON::Validator@5.09

# Создаем рабочую директорию
WORKDIR /app

# Копируем cpanfile и устанавливаем все остальные зависимости.
# cpanm увидит, что JSON::Validator уже установлен, и не будет его трогать.
COPY cpanfile /app/
RUN cpanm --installdeps .

# Копируем все файлы приложения
COPY . /app/

# Открываем порт
EXPOSE 3000

# Правильная команда запуска
CMD ["hypnotoad", "-f", "pastebin.pl"]