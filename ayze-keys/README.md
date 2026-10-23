# AYZE Key Panel

Painel de keys (FastAPI + Jinja2) com API usada pelo `ayzemenu.lua`.

> **Não é um site estático**: o GitHub Pages não executa Python. O código fica no GitHub e o painel roda em um host de Python (ex.: Render).

## Rodar local
```bash
cp .env.example .env   # edite ADMIN_PASSWORD e SESSION_SECRET
pip install -r requirements.txt
python app.py          # http://127.0.0.1:8080/login
```

## Publicar (Render + Neon)
1. Crie um banco grátis em https://neon.tech e copie a connection string (`DATABASE_URL`).
2. No https://render.com: **New > Blueprint** e escolha este repositório (usa `render.yaml`).
3. Defina `ADMIN_PASSWORD` e `DATABASE_URL` (obrigatório para a senha/keys não resetarem). `PUBLIC_BASE_URL` é opcional: o painel detecta a URL do Render sozinho.
4. Abra `/health` (deve mostrar OK) e depois `/login`.
5. No `ayzemenu.lua`, troque `API_BASE` pela URL pública.

Sem `DATABASE_URL` o app usa SQLite, que **é apagado** a cada redeploy em hosts gratuitos.

> **Senha voltando ao padrão / keys sumindo?** Sem `DATABASE_URL` o painel usa SQLite no disco temporário do Render, apagado a cada reinício ou hibernação (plano grátis hiberna após ~15 min sem acesso). Configure o Neon para persistir tudo. O uptime também zera quando o plano grátis hiberna; um monitor (ex.: UptimeRobot em `/health` a cada 5 min) mantém o servidor acordado.
