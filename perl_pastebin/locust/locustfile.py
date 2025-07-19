import random
from locust import HttpUser, task, between

LANGUAGES = ["python", "perl", "javascript", "go", "rust", "plaintext"]

class PastebinUser(HttpUser):
    wait_time = between(1, 2)
    
    # Мы УДАЛИЛИ строчку host = ... отсюда.
    # Теперь хост нужно будет ОБЯЗАТЕЛЬНО указывать в веб-интерфейсе.

    @task
    def create_and_view_paste(self):
        payload = {
            "language": random.choice(LANGUAGES),
            "content": f"Test content from Locust at {self.environment.runner.stats.total.num_requests}"
        }
        
        # ИСПРАВЛЕНИЕ: меняем json=payload на data=payload.
        # Теперь Locust будет отправлять данные как обычная HTML-форма.
        with self.client.post("/", data=payload, catch_response=True, allow_redirects=False) as response:
            if response.status_code == 302:
                redirect_url = response.headers.get('Location')
                if redirect_url:
                    response.success()
                    self.client.get(redirect_url, name="/paste/[id]")
                else:
                    response.failure("Redirect location not found in headers")
            else:
                response.failure(f"Expected a 302 redirect, but got {response.status_code}")
