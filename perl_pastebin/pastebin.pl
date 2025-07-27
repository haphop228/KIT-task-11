#!/usr/bin/env perl

use utf8;
use Mojolicious::Lite;
use Mojolicious::Plugin::Config;
use Mojo::CouchDB;
use Digest::SHA qw(sha1_hex);
use Time::HiRes qw(time sleep);
use Encode qw(encode_utf8);
use Mojo::JSON qw(encode_json);
use Text::Markdown::Discount qw(markdown);
use Path::Tiny;

# --- МОДУЛЬ ДЛЯ ТРАССИРОВКИ ---
use Data::UUID;

our $db_initialized = 0;

# --- КОНФИГУРАЦИЯ СЕРВЕРА ---
app->plugin('Config' => {
  default => {
    hypnotoad => {
      listen  => ['http://*:3000'],
      workers => 1,
      pid_file => '/tmp/pastebin.pid'
    }
  }
});

# --- ИСКУССТВЕННАЯ ЗАДЕРЖКА ---
sub create_artificial_delay {
    my $iterations = 20000;
    my $value = 1;
    for my $i (1..$iterations) { for my $j (1..50) { $value += sqrt($i * $j); } }
    return $value;
}

# --- ИНИЦИАЛИЗАЦИЯ COUCHDB ---
my $couch_url_str = app->config->{couchdb_url} || $ENV{COUCHDB_URL};
die "COUCHDB_URL is not set!" unless $couch_url_str;
my $url_obj = Mojo::URL->new($couch_url_str);
my ($user, $pass) = split ':', $url_obj->userinfo || '';
$url_obj->userinfo(undef);
my $couch = Mojo::CouchDB->new($url_obj, $user, $pass);
my $db = $couch->db('pastes');

# --- Хук для создания БД при старте ---
app->hook(before_server_start => sub {
    return if $db_initialized++;
    my $max_retries = 5;
    my $retry_delay = 2;
    for my $attempt (1..$max_retries) {
        app->log->info("Ensuring 'pastes' database exists (attempt $attempt/$max_retries)...");
        eval { $db->create_db };
        if (!$@) { app->log->info("'pastes' database created successfully."); return; }
        if ($@ =~ /file_exists/) { app->log->info("'pastes' database already exists."); return; }
        app->log->warn("Could not create/verify database (Error: $@). Retrying in $retry_delay seconds...");
        sleep $retry_delay;
    }
    die "Failed to connect to and setup CouchDB after $max_retries attempts.";
});


# --- РЕАЛИЗАЦИЯ ТРАССИРОВКИ ---
my $ug = Data::UUID->new;
app->hook(around_dispatch => sub {
    my ($next, $c) = @_;
    my $trace_id = $c->req->headers->header('X-Trace-ID') || $ug->create_str();
    my $span_id  = $ug->create_str();
    $c->stash(trace_id => $trace_id, span_id => $span_id);
    $c->res->headers->header('X-Trace-ID' => $trace_id);
    $c->res->headers->header('X-Span-ID'  => $span_id);
    return $next->();
});

# --- Хелпер для структурированного логирования ---
helper trace_log => sub {
    my ($c, $level, $message) = @_;
    my $log_entry = {
        timestamp => sprintf("%.6f", Time::HiRes::time()),
        level     => $level,
        trace_id  => $c->stash('trace_id'),
        span_id   => $c->stash('span_id'),
        message   => $message,
        endpoint  => $c->req->url->path->to_string,
        method    => $c->req->method,
    };
    print STDERR encode_json($log_entry), "\n";
};


# --- НАСТРОЙКА PROMETHEUS И ДРУГИЕ ХУКИ ---
app->plugin('Prometheus' => { duration_buckets => [ 0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 5 ], });
my $db_requests_counter = app->prometheus->new_counter( name => 'db_requests_total', help => 'Total requests to the CouchDB.', );
my $queue_duration_histogram = app->prometheus->new_histogram( name => 'http_request_queue_duration_seconds', help => 'Time the request spent in the queue before being processed.', buckets => [0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 5], );

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
app->hook(after_dispatch => sub { shift->res->headers->header('Access-Control-Allow-Origin' => '*'); });

# --- Маршруты (API) ---
get '/' => 'index';

get '/healthz' => sub { shift->render(text => 'OK') };

get '/readyz' => sub {
    my $c = shift;
    $c->trace_log('info', "Performing readiness check.");
    eval { $couch->info };
    if ($@) {
        $c->trace_log('error', "Readiness check failed: $@");
        return $c->render(text => 'CouchDB Unreachable', status => 503);
    }
    $c->trace_log('info', "Readiness check successful.");
    return $c->render(text => 'Ready');
};

# --- ИЗМЕНЕНИЕ ЗДЕСЬ ---
post '/' => sub {
    my $c = shift;
    $c->trace_log('info', "Received request to create a new paste.");

    my $content = $c->param('content') || '';
    my $lang    = $c->param('language') || 'plaintext';

    if (!$content) {
        $c->trace_log('warn', "Validation failed: content is empty.");
        return $c->render(text => 'Content cannot be empty', status => 400);
    }
    $c->trace_log('debug', "Validation successful. Content length: " . length($content));

    my $string_to_hash = encode_utf8($content . time . rand());
    my $id = substr(sha1_hex($string_to_hash), 0, 10);
    $c->trace_log('info', "Generated new paste ID: $id");

    #create_artificial_delay();

    my $doc = { _id => $id, content => $content, language => lc($lang), created => time(), };

    $db_requests_counter->inc();
    $c->trace_log('info', "Attempting to save document to CouchDB...");
    $db->save($doc);
    
    $c->trace_log('info', "Successfully saved document. Redirecting immediately.");
    $c->redirect_to("/paste/" . $id);
};

# --- И ИЗМЕНЕНИЕ ЗДЕСЬ ---
get '/paste/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    $c->trace_log('info', "Received request to view paste with ID: $id");
    
    $db_requests_counter->inc();
    $c->trace_log('info', "Attempting to fetch document from CouchDB...");
    my $doc = eval { $db->get($id) };

    if ($@ || !$doc) {
        $c->trace_log('warn', "Document not found for ID '$id'. Error: $@");
        return $c->render(template => 'not_found', status => 404);
    }

    $c->trace_log('info', "Document found. Rendering page.");
    $c->render('paste', paste => $doc);
};

get '/docs' => sub {
    my $c = shift;
    my $readme_content = eval { path('README.md')->slurp_utf8 };
    if ($@ || !$readme_content) { return $c->render(text => 'README.md not found.', status => 404); }
    my $html = markdown($readme_content);
    return $c->render( template => 'docs', docs_content => $html );
};

app->start;

__DATA__

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

@@ docs.html.ep
% layout 'default';
% title 'Documentation';
<div class="container">
    <%= $docs_content %>
</div>