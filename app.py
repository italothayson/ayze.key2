import csv
import hashlib
import io
import json
import os
import re
import secrets
import string
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import (
    FileResponse,
    HTMLResponse,
    JSONResponse,
    PlainTextResponse,
    RedirectResponse,
    Response,
)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import create_engine, text
from starlette.middleware.sessions import SessionMiddleware

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent
RELEASE_DIR = BASE_DIR / "releases"
TEMPLATE_DIR = BASE_DIR / "templates"
STATIC_DIR = BASE_DIR / "static"
RELEASE_DIR.mkdir(exist_ok=True)

APP_VERSION = "2.0"
STARTED_AT = time.time()

ADMIN_USER = os.getenv("ADMIN_USER", "admin").strip() or "admin"
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "troque-esta-senha")
SESSION_SECRET = os.getenv("SESSION_SECRET", "troque-por-uma-chave-grande-e-aleatoria")


def _is_local_url(url: str) -> bool:
    return (not url) or any(h in url.lower() for h in ("127.0.0.1", "localhost", "0.0.0.0", "[::1]"))


# URL pública: PUBLIC_BASE_URL (ex.: https://ayzekeys.discloud.app); se vazia/local,
# é detectada pelos headers do proxy a cada requisição.
_env_url = os.getenv("PUBLIC_BASE_URL", "").strip().rstrip("/")
PUBLIC_BASE_URL = _env_url or "http://127.0.0.1:8080"
DEFAULT_VERSION = os.getenv("DEFAULT_VERSION", "1.0.0")
PORT = int(os.getenv("PORT", "8080"))

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
if not DATABASE_URL:
    DATABASE_URL = f"sqlite:///{(BASE_DIR / 'ayze.db').as_posix()}"
elif DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = "postgresql+psycopg://" + DATABASE_URL[len("postgres://"):]
elif DATABASE_URL.startswith("postgresql://") and "+psycopg" not in DATABASE_URL:
    DATABASE_URL = "postgresql+psycopg://" + DATABASE_URL[len("postgresql://"):]

engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_recycle=240, future=True)

app = FastAPI(title="Ayze Key Panel", docs_url=None, redoc_url=None)
app.add_middleware(
    SessionMiddleware,
    secret_key=SESSION_SECRET,
    session_cookie="ayze_admin",
    max_age=60 * 60 * 12,
    same_site="lax",
    https_only=PUBLIC_BASE_URL.lower().startswith("https://"),
)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
templates = Jinja2Templates(directory=str(TEMPLATE_DIR))

# ------------------------------------------------------------------ settings

DEFAULT_SETTINGS = {
    "panel_name": "AYZE",
    "key_prefix": "AYZE",
    "accent": "#8b5cf6",
    "bg_style": "aurora",
    "animations": "1",
    "compact": "0",
    "default_amount": "1",
    "default_unit": "days",
    "tz_offset": "-3",
    "rows_per_page": "25",
    "online_minutes": "15",
    "admin_user": "",
    "admin_pass_hash": "",
}
ACCENTS = {
    "Violeta": "#8b5cf6",
    "Carmesim": "#ef4444",
    "Ciano": "#22d3ee",
    "Esmeralda": "#10b981",
    "Âmbar": "#f59e0b",
    "Rosa": "#ec4899",
    "Azul": "#3b82f6",
    "Lima": "#a3e635",
}
_settings_cache = None


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def now_iso() -> str:
    return now_utc().isoformat()


def db_fetchone(sql: str, params=None):
    with engine.begin() as conn:
        row = conn.execute(text(sql), params or {}).mappings().first()
        return dict(row) if row else None


def db_fetchall(sql: str, params=None):
    with engine.begin() as conn:
        return [dict(r) for r in conn.execute(text(sql), params or {}).mappings().all()]


def db_execute(sql: str, params=None):
    with engine.begin() as conn:
        conn.execute(text(sql), params or {})


def get_settings(strict: bool = False) -> dict:
    """Lê as configurações (com cache).

    Se o banco falhar, NÃO guardamos os padrões no cache — antes isso fazia a senha
    personalizada "sumir" (voltava para a do .env) até o próximo reinício.
    Com strict=True a falha é propagada (usado no login).
    """
    global _settings_cache
    if _settings_cache is None:
        data = dict(DEFAULT_SETTINGS)
        try:
            for r in db_fetchall("SELECT k, v FROM settings"):
                data[r["k"]] = r["v"]
        except Exception:
            if strict:
                raise
            return data  # sem cachear
        _settings_cache = data
    return _settings_cache


def set_setting(key: str, value: str):
    global _settings_cache
    with engine.begin() as conn:
        res = conn.execute(text("UPDATE settings SET v = :v WHERE k = :k"), {"k": key, "v": value})
        if not res.rowcount:
            conn.execute(text("INSERT INTO settings (k, v) VALUES (:k, :v)"), {"k": key, "v": value})
    _settings_cache = None


def log_event(kind: str, message: str):
    try:
        db_execute(
            "INSERT INTO activity (id, created_at, kind, message) VALUES (:id, :c, :k, :m)",
            {"id": uuid.uuid4().hex, "c": now_iso(), "k": kind[:24], "m": message[:400]},
        )
        if secrets.randbelow(40) == 0:
            db_execute(
                "DELETE FROM activity WHERE id NOT IN "
                "(SELECT id FROM activity ORDER BY created_at DESC LIMIT 1500)"
            )
    except Exception:
        pass


def init_db():
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS licenses (
                key VARCHAR(80) PRIMARY KEY,
                client_name VARCHAR(80),
                created_at VARCHAR(64) NOT NULL,
                expires_at VARCHAR(64),
                permanent INTEGER NOT NULL DEFAULT 0,
                device_id VARCHAR(255),
                revoked INTEGER NOT NULL DEFAULT 0,
                last_login VARCHAR(64)
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS release (
                id INTEGER PRIMARY KEY,
                version VARCHAR(32) NOT NULL,
                filename VARCHAR(255),
                sha256 VARCHAR(128),
                force_update INTEGER NOT NULL DEFAULT 1,
                updated_at VARCHAR(64) NOT NULL
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS settings (
                k VARCHAR(64) PRIMARY KEY,
                v TEXT
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS activity (
                id VARCHAR(40) PRIMARY KEY,
                created_at VARCHAR(64) NOT NULL,
                kind VARCHAR(24) NOT NULL,
                message VARCHAR(400) NOT NULL
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS release_history (
                id VARCHAR(40) PRIMARY KEY,
                version VARCHAR(32) NOT NULL,
                filename VARCHAR(255),
                sha256 VARCHAR(128),
                size INTEGER,
                force_update INTEGER NOT NULL DEFAULT 1,
                created_at VARCHAR(64) NOT NULL
            )
        """))
        row = conn.execute(text("SELECT id FROM release WHERE id = 1")).mappings().first()
        if not row:
            conn.execute(
                text("""
                    INSERT INTO release
                    (id, version, filename, sha256, force_update, updated_at)
                    VALUES (1, :version, NULL, NULL, 1, :updated_at)
                """),
                {"version": DEFAULT_VERSION, "updated_at": now_iso()},
            )
    # colunas novas (compatível com SQLite e PostgreSQL)
    for ddl in ("ALTER TABLE licenses ADD COLUMN note VARCHAR(255)",):
        try:
            with engine.begin() as conn:
                conn.execute(text(ddl))
        except Exception:
            pass


# ------------------------------------------------------------------ helpers

def parse_expiry(value):
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


def local_tz():
    try:
        return timezone(timedelta(hours=int(get_settings().get("tz_offset", "-3"))))
    except Exception:
        return timezone(timedelta(hours=-3))


def fmt_dt(value, with_seconds=False):
    dt = parse_expiry(value)
    if not dt:
        return "—"
    fmt = "%d/%m/%Y %H:%M:%S" if with_seconds else "%d/%m/%Y %H:%M"
    return dt.astimezone(local_tz()).strftime(fmt)


def time_ago(value):
    dt = parse_expiry(value)
    if not dt:
        return "nunca"
    sec = int((now_utc() - dt).total_seconds())
    if sec < 0:
        sec = 0
    if sec < 60:
        return "agora mesmo"
    if sec < 3600:
        return f"há {sec // 60} min"
    if sec < 86400:
        return f"há {sec // 3600} h"
    if sec < 86400 * 30:
        return f"há {sec // 86400} d"
    return fmt_dt(value)


def hex_to_rgb(value: str) -> str:
    v = (value or "#8b5cf6").lstrip("#")
    if len(v) != 6:
        v = "8b5cf6"
    try:
        return f"{int(v[0:2], 16)},{int(v[2:4], 16)},{int(v[4:6], 16)}"
    except ValueError:
        return "139,92,246"


templates.env.filters["fmt_dt"] = fmt_dt
templates.env.filters["time_ago"] = time_ago
templates.env.filters["rgb"] = hex_to_rgb
templates.env.filters["uptime"] = fmt_uptime


def duration_delta(kind: str, amount: int) -> timedelta:
    amount = max(1, min(int(amount), 10000))
    kind = kind.lower().strip()
    if kind == "hours":
        return timedelta(hours=amount)
    if kind == "days":
        return timedelta(days=amount)
    if kind == "months":
        return timedelta(days=30 * amount)
    if kind == "years":
        return timedelta(days=365 * amount)
    raise ValueError("invalid duration")


def clean_prefix(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9]", "", str(value or "")).upper()[:10]
    return value or "AYZE"


def generate_key() -> str:
    prefix = clean_prefix(get_settings().get("key_prefix"))
    alphabet = string.ascii_uppercase + string.digits
    while True:
        parts = ["".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(3)]
        value = prefix + "-" + "-".join(parts)
        if not db_fetchone("SELECT key FROM licenses WHERE key = :key", {"key": value}):
            return value


def remaining_text(row) -> str:
    if int(row.get("permanent") or 0):
        return "Permanente"
    expiry = parse_expiry(row.get("expires_at"))
    if not expiry:
        return "Expirada"
    seconds = int((expiry - now_utc()).total_seconds())
    if seconds <= 0:
        return "Expirada"
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes, _ = divmod(seconds, 60)
    if days:
        return f"{days}d {hours}h {minutes}m"
    return f"{hours:02d}h {minutes:02d}m"


def release_info():
    return db_fetchone("SELECT * FROM release WHERE id = 1")


def base_url(request: Request | None = None) -> str:
    """URL pública real do painel (a que o admin está usando), nunca a local por engano."""
    if not _is_local_url(PUBLIC_BASE_URL) or request is None:
        return PUBLIC_BASE_URL
    proto = (request.headers.get("x-forwarded-proto") or request.url.scheme).split(",")[0].strip()
    host = (request.headers.get("x-forwarded-host") or request.headers.get("host") or "").split(",")[0].strip()
    return f"{proto}://{host}" if host else PUBLIC_BASE_URL


def download_url(filename, base: str | None = None):
    return f"{base or PUBLIC_BASE_URL}/download/latest" if filename else ""


def fmt_uptime(seconds) -> str:
    s = max(0, int(seconds or 0))
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    if d:
        return f"{d}d {h}h {m}m"
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    return f"{m}m {s:02d}s"


def patch_lua_version(data: bytes, version: str) -> bytes:
    """Atualiza a versão dentro do .lua. Aceita SCRIPT_VERSION = "x" ou LICENSE_SYSTEM = { VERSION = "x" }."""
    source = data.decode("utf-8", errors="replace")
    patterns = (
        r"(\bSCRIPT_VERSION\s*=\s*['\"])[^'\"]+(['\"])",
        r"(LICENSE_SYSTEM\s*=\s*\{[\s\S]{0,2200}?\bVERSION\s*=\s*['\"])[^'\"]+(['\"])",
    )
    for pattern in patterns:
        patched, count = re.subn(pattern, rf"\g<1>{version}\2", source, count=1)
        if count:
            return patched.encode("utf-8")
    raise ValueError('Nao encontrei a versao no .lua. Use: local SCRIPT_VERSION = "1.0.0"')


def clean_client_name(value) -> str:
    value = " ".join(str(value or "Cliente").replace("|", " ").replace("\n", " ").replace("\r", " ").split())
    return value[:80] or "Cliente"


def validation_payload(row, latest: str) -> str:
    if int(row.get("permanent") or 0):
        expiry = "PERMANENT"
        remaining = -1
    else:
        expiry = str(row.get("expires_at") or "")
        dt = parse_expiry(expiry)
        remaining = max(0, int((dt - now_utc()).total_seconds())) if dt else 0
    return f"VALID|{expiry}|{latest}|{remaining}|{clean_client_name(row.get('client_name'))}"


def check_release_version(version: str, request: Request | None = None):
    rel = release_info()
    latest = rel["version"]
    force = int(rel.get("force_update") or 0)
    url = download_url(rel.get("filename"), base_url(request))
    if force and version != latest:
        return f"UPDATE|{latest}|1|{url}"
    return None


def validate_license_row(row, device: str, latest: str):
    if not row:
        return "INVALID"
    if int(row.get("revoked") or 0):
        return "REVOKED"
    if not int(row.get("permanent") or 0):
        expiration = parse_expiry(row.get("expires_at"))
        if not expiration or now_utc() >= expiration:
            return "EXPIRED"
    saved_device = str(row.get("device_id") or "").strip()
    if saved_device and device and saved_device != device:
        return "DEVICE_MISMATCH"
    return validation_payload(row, latest)


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000).hex()
    return f"{salt}${digest}"


def verify_password(password: str, stored: str) -> bool:
    try:
        salt, digest = stored.split("$", 1)
        test = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000).hex()
        return secrets.compare_digest(test, digest)
    except Exception:
        return False


def enrich(row) -> dict:
    item = dict(row)
    item["remaining"] = remaining_text(row)
    if int(row.get("revoked") or 0):
        item["status"] = "Revogada"
    elif item["remaining"] == "Expirada":
        item["status"] = "Expirada"
    else:
        item["status"] = "Ativa"
    item["permanent"] = int(row.get("permanent") or 0)
    item["revoked"] = int(row.get("revoked") or 0)
    exp = parse_expiry(row.get("expires_at"))
    item["seconds_left"] = -1 if item["permanent"] else (int((exp - now_utc()).total_seconds()) if exp else 0)
    ll = parse_expiry(row.get("last_login"))
    minutes = int(get_settings().get("online_minutes", "15") or 15)
    item["online"] = bool(ll and (now_utc() - ll).total_seconds() < minutes * 60)
    return item


def require_admin(request: Request):
    if not request.session.get("admin"):
        raise HTTPException(status_code=401)


def flash(request: Request, kind: str, message: str):
    items = request.session.get("flash", [])
    items.append([kind, message])
    request.session["flash"] = items[-4:]


def render(request: Request, name: str, active: str, title: str, **ctx):
    s = get_settings()
    rel = release_info()
    data = {
        "request": request,
        "s": s,
        "active": active,
        "title": title,
        "flashes": request.session.pop("flash", []),
        "release": rel,
        "public_url": base_url(request),
        "app_version": APP_VERSION,
        "accents": ACCENTS,
        "admin_name": s.get("admin_user") or ADMIN_USER,
    }
    data.update(ctx)
    return templates.TemplateResponse(name, data)


# ------------------------------------------------------------------ login throttle

_fails: dict = {}


def client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "?"


def locked_seconds(ip: str) -> int:
    info = _fails.get(ip)
    if not info:
        return 0
    count, until = info
    if count >= 5 and until > time.time():
        return int(until - time.time()) + 1
    if until <= time.time() and count >= 5:
        _fails.pop(ip, None)
    return 0


# ------------------------------------------------------------------ saudação inteligente (login)

VISIT_COOKIE = "ayze_visit"


def login_greeting(request: Request) -> dict:
    """Escolhe a saudação conforme o histórico de logins deste navegador (cookie)."""
    raw = request.cookies.get(VISIT_COOKIE, "")
    try:
        count_s, ts_s = raw.split("|", 1)
        count, last = int(count_s), int(ts_s)
    except Exception:
        count, last = 0, 0
    if count <= 0 or not last:
        return {"title": "Bem-vindo", "sub": "Primeiro acesso · painel de licenças"}
    days = max(0, int((time.time() - last) // 86400))
    if days >= 30:
        return {"title": "Quanto tempo!", "sub": f"Faz {days} dias desde seu último acesso"}
    if days >= 7:
        return {"title": "Bem-vindo de volta", "sub": f"Seu último acesso foi há {days} dias"}
    if count >= 20:
        return {"title": "Bem-vindo de volta", "sub": "Acesso restrito · painel de licenças"}
    return {"title": "Bem-vindo de volta", "sub": "Acesso restrito · painel de licenças"}


# ------------------------------------------------------------------ startup / auth

@app.on_event("startup")
def startup():
    init_db()


@app.exception_handler(401)
async def unauthorized_handler(request: Request, exc):
    return RedirectResponse("/login", status_code=303)


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    if not request.session.get("admin"):
        return RedirectResponse("/login", status_code=303)
    return RedirectResponse("/panel", status_code=303)


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    if request.session.get("admin"):
        return RedirectResponse("/panel", status_code=303)
    return templates.TemplateResponse(
        "login.html",
        {"request": request, "error": "", "s": get_settings(), "app_version": APP_VERSION, "greet": login_greeting(request)},
    )


@app.post("/login", response_class=HTMLResponse)
def login(request: Request, username: str = Form(...), password: str = Form(...)):
    s = get_settings()
    ip = client_ip(request)

    def fail(msg, code=401):
        return templates.TemplateResponse(
            "login.html",
            {"request": request, "error": msg, "s": s, "app_version": APP_VERSION, "greet": login_greeting(request)},
            status_code=code,
        )

    try:
        s = get_settings(strict=True)
    except Exception:
        # Banco fora do ar: não deixa logar com a senha do .env no lugar da personalizada.
        return fail("Banco de dados indisponível no momento. Tente de novo em alguns segundos.", 503)

    wait = locked_seconds(ip)
    if wait:
        return fail(f"Muitas tentativas. Aguarde {wait}s para tentar novamente.", 429)

    user = s.get("admin_user") or ADMIN_USER
    stored = s.get("admin_pass_hash")
    valid_user = secrets.compare_digest(username.strip(), user)
    valid_pass = verify_password(password, stored) if stored else secrets.compare_digest(password, ADMIN_PASSWORD)
    if not (valid_user and valid_pass):
        count, _ = _fails.get(ip, (0, 0))
        _fails[ip] = (count + 1, time.time() + 60)
        log_event("security", f"Falha de login de {ip} (usuário '{username.strip()[:30]}')")
        return fail("Usuário ou senha incorretos.")

    _fails.pop(ip, None)
    request.session.clear()
    request.session["admin"] = True
    log_event("auth", f"Login realizado de {ip}")
    try:
        prev = int(request.cookies.get(VISIT_COOKIE, "0|0").split("|", 1)[0])
    except Exception:
        prev = 0
    resp = RedirectResponse("/panel", status_code=303)
    resp.set_cookie(
        VISIT_COOKIE,
        f"{prev + 1}|{int(time.time())}",
        max_age=60 * 60 * 24 * 365 * 2,
        httponly=True,
        samesite="lax",
        secure=PUBLIC_BASE_URL.lower().startswith("https://"),
    )
    return resp


@app.post("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


# ------------------------------------------------------------------ painel: páginas

def all_licenses():
    return [enrich(r) for r in db_fetchall("SELECT * FROM licenses ORDER BY created_at DESC")]


def compute_stats(items):
    st = {
        "total": len(items),
        "ativas": sum(1 for i in items if i["status"] == "Ativa"),
        "expiradas": sum(1 for i in items if i["status"] == "Expirada"),
        "revogadas": sum(1 for i in items if i["status"] == "Revogada"),
        "permanentes": sum(1 for i in items if i["permanent"]),
        "vinculadas": sum(1 for i in items if i.get("device_id")),
        "online": sum(1 for i in items if i["online"]),
        "livres": sum(1 for i in items if not i.get("device_id") and i["status"] == "Ativa"),
    }
    return st


@app.get("/panel", response_class=HTMLResponse)
def panel(request: Request):
    require_admin(request)
    items = all_licenses()
    stats = compute_stats(items)

    # keys criadas por dia (14 dias)
    tz = local_tz()
    today = now_utc().astimezone(tz).date()
    days = [today - timedelta(days=i) for i in range(13, -1, -1)]
    buckets = {d: 0 for d in days}
    for it in items:
        dt = parse_expiry(it.get("created_at"))
        if dt:
            d = dt.astimezone(tz).date()
            if d in buckets:
                buckets[d] += 1
    peak = max(buckets.values()) or 1
    chart = [
        {"label": d.strftime("%d/%m"), "value": v, "pct": int(round(v / peak * 100))}
        for d, v in buckets.items()
    ]

    expiring = sorted(
        [i for i in items if i["status"] == "Ativa" and not i["permanent"] and i["seconds_left"] < 86400 * 3],
        key=lambda i: i["seconds_left"],
    )[:6]
    recent_logins = sorted(
        [i for i in items if i.get("last_login")], key=lambda i: i["last_login"], reverse=True
    )[:6]
    activity = db_fetchall("SELECT * FROM activity ORDER BY created_at DESC LIMIT 8")
    total = stats["total"] or 1
    donut = {
        "ativas": round(stats["ativas"] / total * 100, 2),
        "expiradas": round(stats["expiradas"] / total * 100, 2),
        "revogadas": round(stats["revogadas"] / total * 100, 2),
    }
    server = {
        "db": engine.dialect.name,
        "uptime": int(time.time() - STARTED_AT),
        "since": datetime.fromtimestamp(STARTED_AT, timezone.utc).isoformat(),
    }
    return render(
        request, "dashboard.html", "dashboard", "Dashboard",
        stats=stats, chart=chart, chart_total=sum(buckets.values()), expiring=expiring,
        recent_logins=recent_logins, activity=activity, donut=donut, server=server,
    )


@app.get("/panel/api/stats")
def panel_stats(request: Request):
    require_admin(request)
    return JSONResponse(compute_stats(all_licenses()))


@app.get("/panel/keys", response_class=HTMLResponse)
def panel_keys(request: Request, q: str = Query(default="")):
    require_admin(request)
    items = all_licenses()
    return render(request, "keys.html", "keys", "Keys", licenses=items, stats=compute_stats(items), q=q)


@app.get("/panel/keys/export.csv")
def export_keys(request: Request):
    require_admin(request)
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["key", "cliente", "status", "restante", "criada_em", "expira_em", "pc", "ultimo_login", "nota"])
    for i in all_licenses():
        w.writerow([
            i["key"], i.get("client_name") or "", i["status"], i["remaining"],
            i.get("created_at") or "", i.get("expires_at") or "", i.get("device_id") or "",
            i.get("last_login") or "", i.get("note") or "",
        ])
    log_event("system", "Exportou keys em CSV")
    return Response(
        "\ufeff" + buf.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": "attachment; filename=ayze-keys.csv"},
    )


@app.get("/panel/generate", response_class=HTMLResponse)
def panel_generate(request: Request):
    require_admin(request)
    batch_ts = request.session.pop("last_batch", None)
    batch = []
    if batch_ts:
        batch = [enrich(r) for r in db_fetchall(
            "SELECT * FROM licenses WHERE created_at = :c ORDER BY key", {"c": batch_ts})]
    recent = [enrich(r) for r in db_fetchall("SELECT * FROM licenses ORDER BY created_at DESC LIMIT 5")]
    return render(request, "generate.html", "generate", "Gerar keys", batch=batch, recent=recent)


@app.get("/panel/updates", response_class=HTMLResponse)
def panel_updates(request: Request):
    require_admin(request)
    history = db_fetchall("SELECT * FROM release_history ORDER BY created_at DESC LIMIT 15")
    for h in history:
        h["available"] = bool(h.get("filename") and (RELEASE_DIR / h["filename"]).is_file())
    return render(request, "updates.html", "updates", "Atualizações", history=history)


@app.get("/panel/devices", response_class=HTMLResponse)
def panel_devices(request: Request):
    require_admin(request)
    items = [i for i in all_licenses() if i.get("device_id")]
    items.sort(key=lambda i: i.get("last_login") or "", reverse=True)
    return render(request, "devices.html", "devices", "Dispositivos", devices=items)


@app.get("/panel/activity", response_class=HTMLResponse)
def panel_activity(request: Request, kind: str = Query(default="")):
    require_admin(request)
    if kind:
        rows = db_fetchall(
            "SELECT * FROM activity WHERE kind = :k ORDER BY created_at DESC LIMIT 300", {"k": kind})
    else:
        rows = db_fetchall("SELECT * FROM activity ORDER BY created_at DESC LIMIT 300")
    kinds = [r["kind"] for r in db_fetchall("SELECT DISTINCT kind FROM activity")]
    return render(request, "activity.html", "activity", "Atividade", rows=rows, kinds=sorted(kinds), kind=kind)


@app.get("/panel/api", response_class=HTMLResponse)
def panel_api(request: Request):
    require_admin(request)
    return render(request, "api.html", "api", "API")


@app.get("/panel/settings", response_class=HTMLResponse)
def panel_settings(request: Request):
    require_admin(request)
    items = all_licenses()
    info = {
        "db": engine.dialect.name,
        "db_url_masked": re.sub(r"://([^:/@]+):[^@]*@", r"://\1:••••@", DATABASE_URL),
        "keys": len(items),
        "logs": (db_fetchone("SELECT COUNT(*) AS c FROM activity") or {}).get("c", 0),
        "expired": sum(1 for i in items if i["status"] == "Expirada"),
        "uptime": int(time.time() - STARTED_AT),
        "since": datetime.fromtimestamp(STARTED_AT, timezone.utc).isoformat(),
        "custom_pass": bool(get_settings().get("admin_pass_hash")),
    }
    return render(request, "settings.html", "settings", "Configurações", info=info)


# ------------------------------------------------------------------ painel: ações

@app.post("/panel/key/create")
def panel_key_create(
    request: Request,
    client_name: str = Form(...),
    amount: int = Form(1),
    unit: str = Form("days"),
    quantity: int = Form(1),
    note: str = Form(""),
):
    require_admin(request)
    client_name = clean_client_name(client_name)
    quantity = max(1, min(int(quantity), 100))
    permanent = unit == "permanent"
    created = now_utc()
    expiry = None if permanent else created + duration_delta(unit, amount)
    note = " ".join(note.split())[:250]

    for _ in range(quantity):
        value = generate_key()
        db_execute(
            """
            INSERT INTO licenses (key, client_name, created_at, expires_at, permanent, revoked, note)
            VALUES (:key, :client_name, :created_at, :expires_at, :permanent, 0, :note)
            """,
            {
                "key": value, "client_name": client_name, "created_at": created.isoformat(),
                "expires_at": expiry.isoformat() if expiry else None,
                "permanent": 1 if permanent else 0, "note": note or None,
            },
        )
    request.session["last_batch"] = created.isoformat()
    plano = "permanente" if permanent else f"{amount} {unit}"
    log_event("key", f"Gerou {quantity} key(s) para {client_name} ({plano})")
    flash(request, "ok", f"{quantity} key(s) gerada(s) com sucesso.")
    return RedirectResponse("/panel/generate", status_code=303)


def apply_action(row, action: str, amount: int, unit: str):
    key = row["key"]
    if action == "revoke":
        db_execute("UPDATE licenses SET revoked = 1 WHERE key = :key", {"key": key})
    elif action == "reactivate":
        db_execute("UPDATE licenses SET revoked = 0 WHERE key = :key", {"key": key})
    elif action == "reset_device":
        db_execute("UPDATE licenses SET device_id = NULL WHERE key = :key", {"key": key})
    elif action == "delete":
        db_execute("DELETE FROM licenses WHERE key = :key", {"key": key})
    elif action == "add_time" and not int(row.get("permanent") or 0):
        delta = duration_delta(unit, amount)
        expiry = parse_expiry(row.get("expires_at"))
        base = expiry if expiry and expiry > now_utc() else now_utc()
        db_execute(
            "UPDATE licenses SET expires_at = :expires, revoked = 0 WHERE key = :key",
            {"expires": (base + delta).isoformat(), "key": key},
        )
    else:
        return False
    return True


ACTION_LABELS = {
    "revoke": "Revogou", "reactivate": "Reativou", "reset_device": "Resetou o PC de",
    "delete": "Excluiu", "add_time": "Adicionou tempo em",
}


@app.post("/panel/key/action")
def panel_key_action(
    request: Request,
    key: str = Form(...),
    action: str = Form(...),
    amount: int = Form(1),
    unit: str = Form("days"),
    next: str = Form("/panel/keys"),
):
    require_admin(request)
    row = db_fetchone("SELECT * FROM licenses WHERE key = :key", {"key": key})
    dest = next if next.startswith("/panel") else "/panel/keys"
    if not row:
        flash(request, "err", "Key não encontrada.")
        return RedirectResponse(dest, status_code=303)
    if apply_action(row, action, amount, unit):
        log_event("key", f"{ACTION_LABELS.get(action, action)} {key}")
        flash(request, "ok", f"{ACTION_LABELS.get(action, 'Ação em')} {key}.")
    return RedirectResponse(dest, status_code=303)


@app.post("/panel/key/bulk")
def panel_key_bulk(
    request: Request,
    keys: list[str] = Form(default=[]),
    action: str = Form(...),
    amount: int = Form(1),
    unit: str = Form("days"),
):
    require_admin(request)
    done = 0
    for k in keys[:500]:
        row = db_fetchone("SELECT * FROM licenses WHERE key = :key", {"key": k})
        if row and apply_action(row, action, amount, unit):
            done += 1
    if done:
        log_event("key", f"Ação em massa '{action}' aplicada em {done} key(s)")
        flash(request, "ok", f"Ação aplicada em {done} key(s).")
    else:
        flash(request, "err", "Nenhuma key foi alterada.")
    return RedirectResponse("/panel/keys", status_code=303)


@app.post("/panel/key/edit")
def panel_key_edit(
    request: Request, key: str = Form(...), client_name: str = Form(...), note: str = Form("")
):
    require_admin(request)
    db_execute(
        "UPDATE licenses SET client_name = :n, note = :note WHERE key = :key",
        {"n": clean_client_name(client_name), "note": " ".join(note.split())[:250] or None, "key": key},
    )
    log_event("key", f"Editou dados de {key}")
    flash(request, "ok", "Key atualizada.")
    return RedirectResponse("/panel/keys", status_code=303)


def store_release(version: str, filename: str, sha: str, force: int, size: int):
    db_execute(
        """UPDATE release SET version = :version, filename = :filename, sha256 = :sha,
           force_update = :force, updated_at = :updated WHERE id = 1""",
        {"version": version, "filename": filename, "sha": sha, "force": force, "updated": now_iso()},
    )


def prune_release_files(keep: int = 5):
    rows = db_fetchall("SELECT filename FROM release_history ORDER BY created_at DESC")
    keep_names = {r["filename"] for r in rows[:keep] if r.get("filename")}
    cur = release_info()
    if cur and cur.get("filename"):
        keep_names.add(cur["filename"])
    for f in RELEASE_DIR.glob("csgo-*.lua"):
        if f.name not in keep_names:
            try:
                f.unlink()
            except OSError:
                pass


@app.post("/panel/release")
async def panel_release(
    request: Request,
    version: str = Form(...),
    force_update: str | None = Form(None),
    lua_file: UploadFile = File(...),
):
    require_admin(request)
    version = version.strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise HTTPException(status_code=400, detail="Versao invalida")
    raw = await lua_file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Arquivo vazio")
    try:
        patched = patch_lua_version(raw, version)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    filename = f"csgo-{version}.lua"
    temp = RELEASE_DIR / (filename + ".tmp")
    target = RELEASE_DIR / filename
    temp.write_bytes(patched)
    sha = hashlib.sha256(patched).hexdigest()
    temp.replace(target)

    force = 1 if force_update else 0
    store_release(version, filename, sha, force, len(patched))
    db_execute(
        """INSERT INTO release_history (id, version, filename, sha256, size, force_update, created_at)
           VALUES (:id, :v, :f, :s, :z, :fo, :c)""",
        {"id": uuid.uuid4().hex, "v": version, "f": filename, "s": sha, "z": len(patched),
         "fo": force, "c": now_iso()},
    )
    prune_release_files()
    log_event("update", f"Publicou versão {version} ({'obrigatória' if force else 'opcional'})")
    flash(request, "ok", f"Versão {version} publicada.")
    return RedirectResponse("/panel/updates", status_code=303)


@app.post("/panel/release/activate")
def release_activate(request: Request, hid: str = Form(...)):
    require_admin(request)
    h = db_fetchone("SELECT * FROM release_history WHERE id = :i", {"i": hid})
    if not h or not h.get("filename") or not (RELEASE_DIR / h["filename"]).is_file():
        flash(request, "err", "Arquivo dessa versão não está mais disponível.")
        return RedirectResponse("/panel/updates", status_code=303)
    store_release(h["version"], h["filename"], h["sha256"], int(h.get("force_update") or 0), h.get("size") or 0)
    log_event("update", f"Restaurou versão {h['version']}")
    flash(request, "ok", f"Versão {h['version']} agora é a publicada.")
    return RedirectResponse("/panel/updates", status_code=303)


@app.post("/panel/release/force")
def release_force(request: Request):
    require_admin(request)
    rel = release_info()
    new = 0 if int(rel.get("force_update") or 0) else 1
    db_execute("UPDATE release SET force_update = :f WHERE id = 1", {"f": new})
    log_event("update", f"Atualização {'obrigatória' if new else 'opcional'}")
    flash(request, "ok", "Modo de atualização alterado.")
    return RedirectResponse("/panel/updates", status_code=303)


# ------------------------------------------------------------------ configurações

@app.post("/panel/settings/save")
def settings_save(
    request: Request,
    panel_name: str = Form("AYZE"),
    key_prefix: str = Form("AYZE"),
    accent: str = Form("#8b5cf6"),
    bg_style: str = Form("aurora"),
    animations: str | None = Form(None),
    compact: str | None = Form(None),
    default_amount: int = Form(1),
    default_unit: str = Form("days"),
    tz_offset: int = Form(-3),
    rows_per_page: int = Form(25),
    online_minutes: int = Form(15),
    tab: str = Form("geral"),
):
    require_admin(request)
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", accent):
        accent = "#8b5cf6"
    if bg_style not in ("aurora", "grid", "pure"):
        bg_style = "aurora"
    if default_unit not in ("hours", "days", "months", "years", "permanent"):
        default_unit = "days"
    values = {
        "panel_name": (" ".join(panel_name.split())[:18] or "AYZE").upper(),
        "key_prefix": clean_prefix(key_prefix),
        "accent": accent.lower(),
        "bg_style": bg_style,
        "animations": "1" if animations else "0",
        "compact": "1" if compact else "0",
        "default_amount": str(max(1, min(default_amount, 10000))),
        "default_unit": default_unit,
        "tz_offset": str(max(-12, min(tz_offset, 14))),
        "rows_per_page": str(rows_per_page if rows_per_page in (10, 25, 50, 100) else 25),
        "online_minutes": str(max(1, min(online_minutes, 1440))),
    }
    for k, v in values.items():
        set_setting(k, v)
    log_event("system", "Configurações atualizadas")
    flash(request, "ok", "Configurações salvas.")
    return RedirectResponse(f"/panel/settings#{tab}", status_code=303)


@app.post("/panel/settings/account")
def settings_account(
    request: Request,
    username: str = Form(...),
    current: str = Form(...),
    new_password: str = Form(""),
    confirm: str = Form(""),
):
    require_admin(request)
    try:
        s = get_settings(strict=True)
    except Exception:
        flash(request, "err", "Banco de dados indisponível. Tente novamente.")
        return RedirectResponse("/panel/settings#seguranca", status_code=303)
    stored = s.get("admin_pass_hash")
    ok = verify_password(current, stored) if stored else secrets.compare_digest(current, ADMIN_PASSWORD)
    if not ok:
        flash(request, "err", "Senha atual incorreta.")
        return RedirectResponse("/panel/settings#seguranca", status_code=303)
    username = username.strip()[:40]
    if len(username) < 3:
        flash(request, "err", "O usuário precisa ter ao menos 3 caracteres.")
        return RedirectResponse("/panel/settings#seguranca", status_code=303)
    if new_password:
        if len(new_password) < 8:
            flash(request, "err", "A nova senha precisa ter ao menos 8 caracteres.")
            return RedirectResponse("/panel/settings#seguranca", status_code=303)
        if new_password != confirm:
            flash(request, "err", "A confirmação não confere.")
            return RedirectResponse("/panel/settings#seguranca", status_code=303)
        set_setting("admin_pass_hash", hash_password(new_password))
    set_setting("admin_user", username)
    log_event("security", "Credenciais do administrador alteradas")
    flash(request, "ok", "Credenciais atualizadas.")
    return RedirectResponse("/panel/settings#seguranca", status_code=303)


@app.post("/panel/settings/purge-expired")
def purge_expired(request: Request):
    require_admin(request)
    n = 0
    for i in all_licenses():
        if i["status"] == "Expirada":
            db_execute("DELETE FROM licenses WHERE key = :k", {"k": i["key"]})
            n += 1
    log_event("system", f"Removeu {n} key(s) expirada(s)")
    flash(request, "ok", f"{n} key(s) expirada(s) removida(s).")
    return RedirectResponse("/panel/settings#dados", status_code=303)


@app.post("/panel/settings/clear-logs")
def clear_logs(request: Request):
    require_admin(request)
    db_execute("DELETE FROM activity")
    log_event("system", "Histórico de atividade limpo")
    flash(request, "ok", "Histórico limpo.")
    return RedirectResponse("/panel/settings#dados", status_code=303)


@app.get("/panel/settings/backup.json")
def backup_json(request: Request):
    require_admin(request)
    s = {k: v for k, v in get_settings().items() if k != "admin_pass_hash"}
    payload = {
        "generated_at": now_iso(),
        "app_version": APP_VERSION,
        "settings": s,
        "release": release_info(),
        "licenses": db_fetchall("SELECT * FROM licenses ORDER BY created_at DESC"),
    }
    log_event("system", "Gerou backup JSON")
    return Response(
        json.dumps(payload, ensure_ascii=False, indent=2, default=str),
        media_type="application/json",
        headers={"Content-Disposition": "attachment; filename=ayze-backup.json"},
    )


# ---------------- API usada pelo csgo.lua (inalterada) ----------------

@app.get("/health", response_class=PlainTextResponse)
def health():
    try:
        db_fetchone("SELECT 1 AS ok")
        return "OK"
    except Exception:
        return PlainTextResponse("DB_ERROR", status_code=503)


@app.get("/status", response_class=PlainTextResponse)
def status(request: Request, version: str = Query(default=""), device: str = Query(default="")):
    del device
    forced = check_release_version(version, request)
    if forced:
        return forced
    rel = release_info()
    return f"OK|{rel['version']}|{int(rel.get('force_update') or 0)}|{download_url(rel.get('filename'), base_url(request))}"


@app.get("/validate", response_class=PlainTextResponse)
def validate(
    request: Request,
    key: str = Query(default=""),
    device: str = Query(default=""),
    version: str = Query(default=""),
):
    key = key.strip()
    device = device.strip()

    forced = check_release_version(version, request)
    if forced:
        return forced

    if not key or not device:
        return "INVALID"

    rel = release_info()
    latest = rel["version"]
    row = db_fetchone("SELECT * FROM licenses WHERE key = :key", {"key": key})
    status_text = validate_license_row(row, device, latest)

    if status_text.startswith("VALID|"):
        saved_device = str(row.get("device_id") or "").strip()
        if not saved_device:
            db_execute("UPDATE licenses SET device_id = :device WHERE key = :key", {"device": device, "key": key})
            log_event("api", f"{key} ativada e vinculada ao PC {device[:12]}…")
        db_execute("UPDATE licenses SET last_login = :last_login WHERE key = :key", {"last_login": now_iso(), "key": key})
    elif row and status_text in ("DEVICE_MISMATCH", "REVOKED", "EXPIRED"):
        log_event("security", f"{key} bloqueada: {status_text} (PC {device[:12]}…)")

    return status_text


# Compatibilidade com o cliente AYZE: JSON via POST, sem alterar a API legada.
@app.post("/api/validate")
def ayze_validate(
    key: str = Form(default=""),
    hwid: str = Form(default=""),
    version: str = Form(default=""),
    hb: str = Form(default=""),
):
    key, hwid = key.strip(), hwid.strip()
    rel = release_info()
    latest = rel["version"]
    if not key or not hwid:
        return {"status": "INVALIDA"}
    row = db_fetchone("SELECT * FROM licenses WHERE key = :key", {"key": key})
    result = validate_license_row(row, hwid, latest)
    status_map = {"INVALID": "INVALIDA", "REVOKED": "CANCELADA", "EXPIRED": "EXPIRADA", "DEVICE_MISMATCH": "HWID_INVALIDO"}
    if not result.startswith("VALID|"):
        return {"status": status_map.get(result, "ERRO")}
    if not str(row.get("device_id") or "").strip():
        db_execute("UPDATE licenses SET device_id = :hwid WHERE key = :key", {"hwid": hwid, "key": key})
        log_event("api", f"{key} vinculada ao PC {hwid[:12]}")
    db_execute("UPDATE licenses SET last_login = :date WHERE key = :key", {"date": now_iso(), "key": key})
    expiry = parse_expiry(row.get("expires_at"))
    update = version != latest
    return {
        "status": "VALIDA",
        "expires": 0 if int(row.get("permanent") or 0) else int(expiry.timestamp()) if expiry else 0,
        "update": update,
        "mandatory": bool(update and int(rel.get("force_update") or 0) and rel.get("filename")),
        "version": latest,
    }


@app.post("/api/update/download")
def ayze_download_update(key: str = Form(default=""), hwid: str = Form(default="")):
    row = db_fetchone("SELECT * FROM licenses WHERE key = :key", {"key": key.strip()})
    if not hwid.strip() or not validate_license_row(row, hwid.strip(), release_info()["version"]).startswith("VALID|"):
        raise HTTPException(status_code=403, detail="Licenca invalida")
    filename = release_info().get("filename")
    if not filename:
        raise HTTPException(status_code=404, detail="Nenhuma atualizacao publicada")
    path = RELEASE_DIR / Path(filename).name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Arquivo nao encontrado")
    return FileResponse(path, media_type="text/plain; charset=utf-8")


@app.get("/device-auth", response_class=PlainTextResponse)
def device_auth(request: Request, device: str = Query(default=""), version: str = Query(default="")):
    device = device.strip()

    forced = check_release_version(version, request)
    if forced:
        return forced

    if not device:
        return "NO_LICENSE"

    rel = release_info()
    latest = rel["version"]

    row = db_fetchone(
        """
        SELECT * FROM licenses WHERE device_id = :device
        ORDER BY created_at DESC LIMIT 1
        """,
        {"device": device},
    )
    if not row:
        return "NO_LICENSE"

    status_text = validate_license_row(row, device, latest)
    if status_text.startswith("VALID|"):
        db_execute("UPDATE licenses SET last_login = :last_login WHERE key = :key", {"last_login": now_iso(), "key": row["key"]})
    return status_text


@app.get("/download/latest")
def download_latest():
    rel = release_info()
    filename = rel.get("filename")
    if not filename:
        return PlainTextResponse("NO_RELEASE", status_code=404)
    path = RELEASE_DIR / filename
    if not path.is_file():
        return PlainTextResponse("FILE_NOT_FOUND", status_code=404)
    return FileResponse(path, media_type="text/plain; charset=utf-8", filename="csgo.lua")


if __name__ == "__main__":
    import uvicorn
    init_db()
    uvicorn.run(app, host="0.0.0.0", port=PORT)
