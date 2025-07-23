#!/usr/bin/env perl

use utf8;
use Mojolicious::Lite;
use Mojolicious::Plugin::Config;
use Mojo::CouchDB;
use Digest::SHA qw(sha1_hex);
use Time::HiRes qw(time sleep);

# Конфигурация для Hypnotoad
app->plugin('Config' => {
  default => {
    hypnotoad => {
      listen  => ['http://*:3000'],
      workers => 10,
      pid_file => '/tmp/pastebin.pid'
    }
  }
});

# --- ПРАВИЛЬНАЯ ИНИЦИАЛИЗАЦИЯ СОЕДИНЕНИЯ ---
my $couch_url_str = app->config->{couchdb_url} || $ENV{COUCHDB_URL};
die "COUCHDB_URL is not set!" unless $couch_url_str;

my $url_obj = Mojo::URL->new($couch_url_str);
my ($user, $pass) = split ':', $url_obj->userinfo || '';
$url_obj->userinfo(undef);

my $couch = Mojo::CouchDB->new($url_obj, $user, $pass);
my $db = $couch->db('pastes');

# --- Хук для автоматического создания БД при первом старте ---
app->hook(before_server_start => sub {
    my $max_retries = 5;
    my $retry_delay = 2;
    for my $attempt (1..$max_retries) {
        app->log->info("Ensuring 'pastes' database exists (attempt $attempt/$max_retries)...");
        my $ok = $db->create_db;
        if ($ok) {
            app->log->info("'pastes' database is ready.");
            return;
        }
        app->log->warn("Could not create/verify database. Retrying in $retry_delay seconds...");
        sleep $retry_delay;
    }
    die "Failed to connect to and setup CouchDB after $max_retries attempts.";
});

# Настройка Prometheus
app->plugin('Prometheus' => {
  duration_buckets => [ 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1 ],
});
my $db_requests_counter = app->prometheus->new_counter(
    name => 'db_requests_total',
    help => 'Total requests to the CouchDB.',
);

# --- Маршруты (API) ---

get '/' => 'index';

get '/healthz' => sub { shift->render(text => 'OK') };

get '/readyz' => sub {
    my $c = shift;
    $c->render_later;
    $db->info_p->then( sub { $c->render(text => 'Ready') } )
             ->catch( sub { $c->render(text => 'CouchDB Unreachable', status => 503) } );
};

# --- ИСПРАВЛЕНИЕ: ПЕРЕПИСЫВАЕМ НА СИНХРОННЫЙ КОД ---
post '/' => sub {
    my $c = shift;
    # Убираем render_later, так как операция будет синхронной
    
    my $content = $c->param('content') || '';
    my $lang    = $c->param('language') || 'plaintext';
    return $c->render(text => 'Content cannot be empty.', status => 400) if $content eq '';
    
    my $id = substr(sha1_hex($content . time . rand()), 0, 10);
    
    my $data_to_store = {
        _id      => $id,
        content  => $content,
        language => lc($lang),
        created  => time(),
    };
    
    $db_requests_counter->inc();
    
    # Вызываем СИНХРОННЫЙ метод save, как в документации
    my $res = eval { $db->save($data_to_store) } || {};

    if ($@ || !$res->{ok} || !$res->{id}) {
        $c->app->log->error("Save failed: " . ($@ || $res->{reason} || 'Unknown error'));
        return $c->render(text => 'Save failed', status => 500);
    }

    $c->redirect_to("/paste/" . $res->{id});
};

get '/paste/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    $c->render_later;
    $db_requests_counter->inc();
    $db->get_p($id)->then(sub {
        my $doc = shift;
        return $c->render(template => 'not_found', status => 404) unless $doc;
        $c->render('paste', paste => $doc);
    })->catch(sub {
        my $err = shift;
        $c->app->log->error("CouchDB get error: $err");
        $c->render(template => 'not_found', status => 404);
    });
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
