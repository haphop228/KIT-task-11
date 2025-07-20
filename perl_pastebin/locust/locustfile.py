import random
from locust import HttpUser, task, between

# --- Сценарий 1: Полная нагрузка (создание и чтение) ---
class FullLoadUser(HttpUser):
    wait_time = between(1, 2)
    LANGUAGES = ["python", "perl", "javascript", "go", "rust", "plaintext"]
    @task
    def create_and_view_paste(self):
        payload = { "language": random.choice(self.LANGUAGES), "content": f"Full load test" }
        with self.client.post("/", data=payload, catch_response=True, allow_redirects=False) as r:
            if r.status_code == 302:
                self.client.get(r.headers.get('Location'), name="/paste/[id]")

# --- Сценарий 2: Нагрузка только на чтение ---
class ReadOnlyUser(HttpUser):
    wait_time = between(1, 2)
    def on_start(self):
        with self.client.post("/", data={"language": "text", "content": "read test"}, allow_redirects=False) as r:
            if r.status_code == 302: self.test_paste_url = r.headers.get('Location')
    @task(9)
    def view_paste(self):
        if hasattr(self, 'test_paste_url'): self.client.get(self.test_paste_url, name="/paste/[id]")
    @task(1)
    def create_new_paste_occasionally(self):
        self.client.post("/", data={"language": "go", "content": "new paste"})

# --- Сценарий 3: Нагрузка на технические ручки ---
class HealthCheckUser(HttpUser):
    wait_time = between(1, 3)
    @task(3)
    def check_health(self): self.client.get("/healthz")
    @task(1)
    def check_readiness(self): self.client.get("/readyz")