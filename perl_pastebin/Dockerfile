# Используем официальный, стабильный образ Perl
FROM perl:5.38

# Устанавливаем cpanminus - менеджер пакетов для Perl
RUN curl -L https://cpanmin.us | perl - App::cpanminus

# Создаем рабочую директорию внутри контейнера
WORKDIR /app

# Копируем cpanfile и устанавливаем зависимости.
COPY cpanfile /app/
RUN cpanm --installdeps .

# Копируем все файлы приложения в рабочую директорию
COPY . /app/

# Сообщаем Docker, что наше приложение будет слушать порт 3000
EXPOSE 3000

# ИСПРАВЛЕНИЕ: Запускаем hypnotoad в режиме "foreground" (-f),
# чтобы он не завершался и держал контейнер "живым".
CMD ["hypnotoad", "-f", "pastebin.pl"]
