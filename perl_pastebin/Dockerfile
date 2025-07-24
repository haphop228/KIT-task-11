# ФИНАЛЬНЫЙ DOCKERFILE

# Используем официальный, стабильный образ Perl
FROM perl:5.38

# Устанавливаем системные пакеты, которые могут понадобиться для компиляции
RUN apt-get update && apt-get install -y \
    build-essential \
    zlib1g-dev \
    libssl-dev \
    libprotobuf-c-dev \
    protobuf-c-compiler \
    libffi-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Устанавливаем cpanminus
RUN curl -L https://cpanmin.us | perl - App::cpanminus

# Создаем рабочую директорию
WORKDIR /app

# Копируем правильный cpanfile
COPY cpanfile /app/

# Устанавливаем ВСЕ зависимости одной командой. cpanm сам разберется.
RUN cpanm --installdeps .

# Копируем все файлы приложения
COPY . /app/

# Открываем порт
EXPOSE 3000

# Правильная команда запуска
CMD ["hypnotoad", "-f", "pastebin.pl"]