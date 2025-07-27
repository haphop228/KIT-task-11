# cpanfile

# --- Зависимости для работы приложения ---
requires 'Mojolicious';
requires 'Digest::SHA';
requires 'Time::HiRes';
requires 'Data::Dumper';
requires 'Mojo::CouchDB';
requires 'Mojolicious::Plugin::Config';

# --- Зависимость для метрик ---
requires 'Mojolicious::Plugin::Prometheus';

# --- ЗАВИСИМОСТИ ДЛЯ ТРЕЙСИНГА (OpenTelemetry) ---
# Указываем только то, что нам действительно нужно. Остальное - детали реализации.
requires 'Mojolicious::Plugin::OpenTelemetry';
requires 'OpenTelemetry::Exporter::OTLP';
requires 'Devel::NYTProf';
requires 'Text::Markdown'; # Для отображения README в браузере
requires 'Text::Markdown::Discount'; # Более мощный парсер с поддержкой таблиц

requires 'OpenTelemetry::SDK';
requires 'Data::UUID';
#requires 'Google::ProtocolBuffers::Dynamic';
