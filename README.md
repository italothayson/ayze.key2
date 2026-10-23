# AYZE Key Panel (Discloud)

Site FastAPI + Jinja2 com a API usada pelo `ayzemenu.lua`.

## Publicar na Discloud
1. Edite o `.env`: defina `ADMIN_PASSWORD` (e `ADMIN_USER` se quiser).
2. Se o subdomínio `ayzekeys` já estiver em uso, troque `ID=` no `discloud.config`,
   `PUBLIC_BASE_URL` no `.env` e `API_BASE` no `ayzemenu.lua` para o mesmo nome.
3. Zipe o conteúdo da pasta (o `discloud.config` deve ficar na RAIZ do zip) e envie
   pelo bot (`/upload`), pelo painel, ou use `discloud upload`.
4. Acesse `https://SEU-ID.discloud.app/health` (deve mostrar OK) e depois `/login`.

## Rodar local
```bash
pip install -r requirements.txt
python app.py   # http://127.0.0.1:8080/login
```

## Observações
- Sites na Discloud rodam na porta 8080 (já é o padrão do app).
- O banco padrão é SQLite (`ayze.db`) no disco da Discloud. Faça backup antes de re-uploads,
  ou use `DATABASE_URL` (Postgres) para ficar independente do deploy.
