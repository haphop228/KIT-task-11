#!/usr/bin/env perl

use utf8;
use Mojolicious::Lite;
use Mojolicious::Plugin::Prometheus;

use DB_File;
use Fcntl qw(:flock O_RDWR O_CREAT);
use Digest::SHA qw(sha1_hex);
use Time::HiRes qw(time);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Encode qw(encode_utf8 decode_utf8);
use Mojo::JSON qw(to_json from_json);

# --- Конфигурация приложения ---
my $db_dir    = abs_path('data');
my $db_path   = "$db_dir/pastes.db";
my $lock_file = "$db_dir/.lock";

make_path($db_dir) or die "Cannot create directory $db_dir: $!" unless -d $db_dir;
open(my $lock_fh, '>>', $lock_file) or die "Cannot create lock file: $!";
close($lock_fh);

tie my %pastes, 'DB_File', $db_path, O_RDWR|O_CREAT, 0644
  or die "Cannot open database file $db_path: $!";

# ИСПРАВЛЕНИЕ 1: Загружаем плагин без неверной конфигурации
plugin 'Prometheus';

# ИСПРАВЛЕНИЕ 2: Получаем объект Net::Prometheus и регистрируем счетчик ОДИН РАЗ.
# Мы сохраняем объект счетчика в переменную $db_requests_counter.
my $db_requests_counter = app->prometheus->new_counter(
    name => 'db_requests_total',
    help => 'Total requests to the database file.',
);

# --- Маршруты (API) ---

get '/' => 'index';

post '/' => sub {
    my $c = shift;
    my $content = $c->param('content') || '';
    my $lang    = $c->param('language') || 'plaintext';

    return $c->render(text => 'Content cannot be empty.', status => 400) if $content eq '';

    my $string_to_hash = encode_utf8($content . time . rand());
    my $id = substr(sha1_hex($string_to_hash), 0, 10);

    my $data_to_store = {
        content  => $content,
        language => lc($lang),
        created  => time(),
    };

    # ИСПРАВЛЕНИЕ 3: Используем переменную-счетчик для инкремента
    $db_requests_counter->inc();

    open(my $lock, '>>', $lock_file) or die "Cannot open lock file: $!";
    flock($lock, LOCK_EX) or die "Cannot lock database: $!";
    $pastes{$id} = encode_utf8(to_json($data_to_store));
    flock($lock, LOCK_UN);
    close($lock);

    $c->redirect_to("/paste/$id");
};

get '/paste/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');

    # ИСПРАВЛЕНИЕ 3: Используем ту же переменную-счетчик
    $db_requests_counter->inc();

    open(my $lock, '>>', $lock_file) or die "Cannot open lock file: $!";
    flock($lock, LOCK_SH) or die "Cannot lock database: $!";
    my $stored_data_bytes = $pastes{$id};
    flock($lock, LOCK_UN);
    close($lock);

    unless (defined $stored_data_bytes) {
        return $c->render(template => 'not_found', status => 404);
    }

    my $paste = from_json(decode_utf8($stored_data_bytes));
    $c->render('paste', paste => $paste);
};

app->start;

__DATA__

@@ not_found.html.ep
% layout 'default';
% title 'Not Found';
<div class="container">
  <h1>404 - Paste Not Found</h1>
  <p>The paste you are looking for does not exist or has been deleted.</p>
  <a href="/" role="button">Create a New Paste</a>
</div>