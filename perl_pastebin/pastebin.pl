#!/usr/bin/env perl

use utf8;
use Mojolicious::Lite;
use Mojolicious::Plugin::Config;
use Mojo::CouchDB;
use Digest::SHA qw(sha1_hex);
use Time::HiRes qw(time sleep);
use Encode qw(encode_utf8);
use Mojo::JSON qw(encode_json);

# ВАЖНО: Мы больше НЕ инициализируем OpenTelemetry вручную здесь.
# Плагин сделает это за нас.

our $db_initialized = 0;

# --- ОКОНЧАТЕЛЬНАЯ КОНФИГУРАЦИЯ СЕРВЕРА ---
app->plugin('Config' => {
  default => {
    hypnotoad => {
      listen  => ['http://*:3000'],
      workers => 1,
      pid_file => '/tmp/pastebin.pid'
    }
  }
});

# --- ИНИЦИАЛИЗАЦИЯ СОЕДИНЕНИЯ ---
my $couch_url_str = app->config->{couchdb_url} || $ENV{COUCHDB_URL};
die "COUCHDB_URL is not set!" unless $couch_url_str;
my $url_obj = Mojo::URL->new($couch_url_str);
my ($user, $pass) = split ':', $url_obj->userinfo || '';
$url_obj->userinfo(undef);
my $couch = Mojo::CouchDB->new($url_obj, $user, $pass);
my $db = $couch->db('pastes');

# --- Хук для автоматического создания БД ---
app->hook(before_server_start => sub {
    return if $db_initialized++;
    my $max_retries = 5;
    my $retry_delay = 2;
    for my $attempt (1..$max_retries) {
        app->log->info("Ensuring 'pastes' database exists (attempt $attempt/$max_retries)...");
        eval { $db->create_db };
        if (!$@) {
            app->log->info("'pastes' database created successfully.");
            return;
        }
        if ($@ =~ /file_exists/) {
            app->log->info("'pastes' database already exists.");
            return;
        }
        app->log->warn("Could not create/verify database (Error: $@). Retrying in $retry_delay seconds...");
        sleep $retry_delay;
    }
    die "Failed to connect to and setup CouchDB after $max_retries attempts.";
});

# --- НАСТРОЙКА PROMETHEUS ---
app->plugin('Prometheus' => {
  duration_buckets => [ 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5 ],
});
my $db_requests_counter = app->prometheus->new_counter(
    name => 'db_requests_total',
    help => 'Total requests to the CouchDB.',
);
my $queue_duration_histogram = app->prometheus->new_histogram(
    name    => 'http_request_queue_duration_seconds',
    help    => 'Time the request spent in the queue before being processed.',
    buckets => [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
);

# --- ПРАВИЛЬНОЕ ПОДКЛЮЧЕНИЕ ПЛАГИНА OpenTelemetry ---
# Вся конфигурация передается прямо сюда.
app->plugin('OpenTelemetry' => {
    service_name => 'pastebin-service',
    exporter => {
        module   => 'OTLP',
        endpoint => 'http://jaeger:4318/v1/traces',
    }
});

# --- ХУК ДЛЯ ИЗМЕРЕНИЯ ВРЕМЕНИ В ОЧЕРЕДИ ---
app->hook(around_dispatch => sub {
    my ($next, $c) = @_;
    if (my $start_header = $c->req->headers->header('X-Request-Start')) {
        if ($start_header =~ s/^t=//) {
            my $now = Time::HiRes::time();
            my $queue_time = $now - $start_header;
            $queue_duration_histogram->observe($queue_time) if $queue_time > 0;
        }
    }
    return $next->();
});

# --- ХУК ДЛЯ РЕШЕНИЯ ПРОБЛЕМЫ CORS ---
app->hook(after_dispatch => sub {
    my $c = shift;
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
});

# --- Маршруты (API) ---
get '/' => 'index';
get '/healthz' => sub { shift->render(text => 'OK') };
get '/readyz' => sub {
    my $c = shift;
    eval { $couch->info };
    if ($@) {
        $c->app->log->error("Readiness check failed: $@");
        return $c->render(text => 'CouchDB Unreachable', status => 503);
    }
    return $c->render(text => 'Ready');
};

post '/' => sub {
    my $c = shift;
    my $content = $c->param('content') || '';
    my $lang    = $c->param('language') || 'plaintext';
    return $c->render(text => 'Content cannot be empty', status => 400) unless $content;
    my $string_to_hash = encode_utf8($content . time . rand());
    my $id = substr(sha1_hex($string_to_hash), 0, 10);
    my $doc = { _id => $id, content => $content, language => lc($lang), created => time() };
    $db_requests_counter->inc();
    my $res;

    # --- ПРАВИЛЬНОЕ ПОЛУЧЕНИЕ ТРЕЙСЕРА ---
    my $tracer = $c->app->opentelemetry->get_tracer;
    my $span = $tracer->start_span('CouchDB SAVE');
    $span->set_attribute('db.system', 'couchdb');
    $span->set_attribute('db.name', 'pastes');
    $span->set_attribute('doc.id', $id);

    eval { $res = $db->save($doc); };

    if ($@) {
        $span->record_exception($@);
        $span->set_status('error', 'Database save failed');
    }
    $span->end_span;

    if ($@) {
        $c->app->log->error("CouchDB save failed with a fatal error: $@");
        return $c->render(text => 'Failed to save paste due to a critical error', status => 500);
    }
    if ($res && ($res->{id} || $res->{ok})) {
        $c->redirect_to("/paste/" . ($res->{id} || $id));
    } else {
        $c->app->log->error("Failed to save paste. Response: " . Mojo::JSON::encode_json($res));
        $c->render(text => 'Failed to save paste (invalid response)', status => 500);
    }
};

get '/paste/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    $db_requests_counter->inc();
    my $doc;

    # --- ПРАВИЛЬНОЕ ПОЛУЧЕНИЕ ТРЕЙСЕРА ---
    my $tracer = $c->app->opentelemetry->get_tracer;
    my $span = $tracer->start_span('CouchDB GET');
    $span->set_attribute('db.system', 'couchdb');
    $span->set_attribute('db.name', 'pastes');
    $span->set_attribute('doc.id', $id);

    eval { $doc = $db->get($id) };

    if ($@) {
        $span->record_exception($@);
        $span->set_status('error', 'Database get failed');
    }
    $span->end_span;

    if ($@ || !$doc) {
        $c->app->log->warn("Document not found for ID '$id'. Error: $@") if $@;
        return $c->render(template => 'not_found', status => 404);
    }
    $c->render('paste', paste => $doc);
};
app->start;

__DATA__

# ... (вся секция __DATA__ без изменений) ...


@@ index.html.ep
% layout 'default';
% title 'Create New Paste';
<h1>Create a New Paste</h1>
<form action="/" method="POST">
  <figure>
    <textarea id="content" name="content" rows="18" placeholder="Paste your code here..." required></textarea>
  </figure>
  <div class="grid">
    <label for="language">
      Syntax Language
      <select id="language" name="language">
        <option value="plaintext" selected>Plain Text</option>
        <option value="perl">Perl</option>
        <option value="python">Python</option>
        <option value="javascript">JavaScript</option>
        <option value="html">HTML</option>
        <option value="css">CSS</option>
        <option value="json">JSON</option>
        <option value="sql">SQL</option>
        <option value="bash">Bash / Shell</option>
        <option value="c">C</option>
        <option value="cpp">C++</option>
        <option value="csharp">C#</option>
        <option value="java">Java</option>
        <option value="go">Go</option>
        <option value="rust">Rust</option>
        <option value="ruby">Ruby</option>
        <option value="yaml">YAML</option>
        <option value="dockerfile">Dockerfile</option>
      </select>
    </label>
    <button type="submit">Create Paste</button>
  </div>
</form>
@@ not_found.html.ep
% layout 'default';
% title 'Not Found';
<div class="container">
  <h1>404 - Paste Not Found</h1>
  <p>The paste you are looking for does not exist or has been deleted.</p>
  <a href="/" role="button">Create a New Paste</a>
</div>
@@ paste.html.ep
% layout 'default';
% title 'View Paste';
<nav>
  <ul><li><strong>Language: <%= $paste->{language} %></strong></li></ul>
  <ul><li><a href="/" role="button" class="secondary">Create New</a></li></ul>
</nav>
<pre><code class="language-<%= $paste->{language} %>"><%= $paste->{content} %></code></pre>
<% content_for 'scripts' => begin %>
  <script src="/js/highlight.min.js"></script>
  <script>hljs.highlightAll();</script>
<% end %>
@@ layouts/default.html.ep
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><%= title %></title>
    <link rel="stylesheet" href="/css/pico.min.css" />
    <link rel="stylesheet" href="/css/github-dark.min.css">
    <style>
      main { padding-top: 0; }
      pre { padding: 1.5em; border-radius: 8px; }
      .container { max-width: 960px; }
    </style>
</head>
<body>
    <main class="container">
        <%= content %>
    </main>
    <%= content_for 'scripts' %>
</body>
</html>