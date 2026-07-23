import os
import time

from flask import Flask, jsonify, redirect, render_template_string, request, url_for
import psycopg
from psycopg.rows import dict_row

app = Flask(__name__)

SITE_ID = os.getenv("SITE_ID", "unknown")
SITE_NAME = os.getenv("SITE_NAME", SITE_ID)
FRONTEND_ROLE = os.getenv("FRONTEND_ROLE", "standby").lower()
DB_USERNAME = os.environ["DB_USERNAME"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_DATABASE = os.getenv("DB_DATABASE", "ledger")
WRITE_HOSTS = os.getenv("WRITE_HOSTS", "ledger-postgres-site-a,ledger-postgres-site-b")
WRITE_PORTS = os.getenv("WRITE_PORTS", "5432,5432")
LOCAL_READ_HOST = os.getenv("LOCAL_READ_HOST", "ledger-db-rw")
LOCAL_DB_LABEL = os.getenv("LOCAL_DB_LABEL", "Local PostgreSQL")


def connect_write():
    return psycopg.connect(
        host=WRITE_HOSTS,
        port=WRITE_PORTS,
        dbname=DB_DATABASE,
        user=DB_USERNAME,
        password=DB_PASSWORD,
        target_session_attrs="read-write",
        connect_timeout=5,
        application_name=f"ledger-web-{SITE_ID}",
        autocommit=True,
        row_factory=dict_row,
    )


def connect_local():
    return psycopg.connect(
        host=LOCAL_READ_HOST,
        port=5432,
        dbname=DB_DATABASE,
        user=DB_USERNAME,
        password=DB_PASSWORD,
        connect_timeout=5,
        application_name=f"ledger-local-read-{SITE_ID}",
        autocommit=True,
        row_factory=dict_row,
    )


def ensure_schema():
    with connect_write() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS public.ledger_entries (
                    id BIGSERIAL PRIMARY KEY,
                    origin_site TEXT NOT NULL,
                    message TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )


def database_status(connection_factory):
    with connection_factory() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                  pg_is_in_recovery() AS in_recovery,
                  inet_server_addr()::text AS server_address,
                  inet_server_port() AS server_port,
                  current_database() AS database_name,
                  current_user AS database_user,
                  now() AS database_time
                """
            )
            return cur.fetchone()


def local_entries(limit=30):
    with connect_local() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, origin_site, message, created_at
                FROM public.ledger_entries
                ORDER BY id DESC
                LIMIT %s
                """,
                (limit,),
            )
            return cur.fetchall()


def insert_entry(message):
    ensure_schema()
    with connect_write() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO public.ledger_entries(origin_site, message)
                VALUES (%s, %s)
                RETURNING id, origin_site, message, created_at
                """,
                (SITE_ID, message),
            )
            return cur.fetchone()


def wait_until_local(entry_id, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with connect_local() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id FROM public.ledger_entries WHERE id = %s",
                        (entry_id,),
                    )
                    if cur.fetchone():
                        return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


def safe_status():
    result = {
        "site_id": SITE_ID,
        "site_name": SITE_NAME,
        "frontend_role": FRONTEND_ROLE,
        "active": FRONTEND_ROLE == "active",
        "local_read_host": LOCAL_READ_HOST,
        "local_db_label": LOCAL_DB_LABEL,
        "write_hosts": WRITE_HOSTS,
        "write_ports": WRITE_PORTS,
        "database": DB_DATABASE,
        "database_user": DB_USERNAME,
        "local_database": None,
        "write_database": None,
        "local_error": None,
        "write_error": None,
    }
    try:
        result["local_database"] = database_status(connect_local)
    except Exception as exc:
        result["local_error"] = str(exc)
    try:
        result["write_database"] = database_status(connect_write)
    except Exception as exc:
        result["write_error"] = str(exc)
    return result


PAGE = r"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="15">
  <title>Multi-Site Ledger - {{ status.site_name }}</title>
  <style>
    :root { color-scheme: light; --red:#ee0000; --dark:#151515; --muted:#6a6e73; --line:#d2d2d2; --green:#3e8635; }
    * { box-sizing: border-box; }
    body { margin:0; font-family:"Red Hat Text",Arial,sans-serif; background:#f5f5f5; color:var(--dark); }
    header { background:#151515; color:white; padding:20px 28px; border-top:5px solid var(--red); }
    header h1 { margin:0 0 4px; font-size:26px; }
    header p { margin:0; color:#d2d2d2; }
    main { max-width:1180px; margin:24px auto; padding:0 20px 40px; }
    .banner { padding:16px 20px; border-radius:8px; color:white; font-size:20px; font-weight:700; margin-bottom:20px; }
    .active { background:var(--green); }
    .standby { background:#795600; }
    .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(230px,1fr)); gap:14px; margin-bottom:20px; }
    .card { background:white; border:1px solid var(--line); border-radius:8px; padding:16px; box-shadow:0 2px 4px rgba(0,0,0,.05); }
    .label { color:var(--muted); font-size:13px; text-transform:uppercase; letter-spacing:.04em; }
    .value { margin-top:7px; font-size:18px; font-weight:700; word-break:break-word; }
    .ok { color:var(--green); } .warn { color:#795600; } .bad { color:#c9190b; }
    code { display:block; background:#f0f0f0; padding:10px; margin-top:8px; border-radius:5px; white-space:normal; word-break:break-all; }
    form { display:flex; gap:10px; margin-top:12px; }
    input { flex:1; min-width:0; padding:11px; border:1px solid #8a8d90; border-radius:4px; font-size:16px; }
    button { background:var(--red); color:white; border:0; border-radius:4px; padding:11px 18px; font-weight:700; cursor:pointer; }
    button:disabled { background:#8a8d90; cursor:not-allowed; }
    table { width:100%; border-collapse:collapse; background:white; }
    th,td { text-align:left; padding:11px; border-bottom:1px solid #e7e7e7; }
    th { background:#f0f0f0; }
    .notice { background:#e7f1fa; border-left:4px solid #0066cc; padding:12px; margin:14px 0; }
    .error { background:#faeae8; border-left:4px solid #c9190b; padding:12px; margin:14px 0; }
    footer { color:var(--muted); margin-top:18px; font-size:13px; }
  </style>
</head>
<body>
<header>
  <h1>OpenShift Multi-Site Ledger</h1>
  <p>CloudNativePG · Red Hat Service Interconnect · Vault · External Secrets · Argo CD</p>
</header>
<main>
  <div class="banner {{ 'active' if status.active else 'standby' }}">
    {{ status.site_name }} — {{ status.frontend_role|upper }}
  </div>

  {% if created %}
    <div class="notice">Record {{ created }} was created from {{ status.site_name }}. Local visibility: {{ 'replicated' if replicated else 'still replicating' }}.</div>
  {% endif %}
  {% if error %}<div class="error">{{ error }}</div>{% endif %}

  <div class="grid">
    <div class="card"><div class="label">Application site</div><div class="value">{{ status.site_id }}</div></div>
    <div class="card"><div class="label">Frontend role</div><div class="value {{ 'ok' if status.active else 'warn' }}">{{ status.frontend_role|upper }}</div></div>
    <div class="card"><div class="label">Local database</div><div class="value">{{ status.local_db_label }}</div></div>
    <div class="card"><div class="label">Local PostgreSQL role</div><div class="value">{% if status.local_database %}{{ 'REPLICA / RECOVERY' if status.local_database.in_recovery else 'PRIMARY / READ-WRITE' }}{% else %}<span class="bad">UNAVAILABLE</span>{% endif %}</div></div>
    <div class="card"><div class="label">Write path</div><div class="value">{% if status.write_database %}<span class="ok">WRITABLE PRIMARY REACHABLE</span>{% else %}<span class="bad">UNAVAILABLE</span>{% endif %}</div></div>
    <div class="card"><div class="label">Secrets</div><div class="value">Vault → External Secrets</div></div>
  </div>

  <div class="card">
    <div class="label">Write connection string</div>
    <code>host={{ status.write_hosts }} port={{ status.write_ports }} dbname={{ status.database }} user={{ status.database_user }} target_session_attrs=read-write</code>
    <div class="label" style="margin-top:14px">Local read connection string</div>
    <code>host={{ status.local_read_host }} port=5432 dbname={{ status.database }} user={{ status.database_user }}</code>
  </div>

  <div class="card" style="margin-top:20px">
    <h2 style="margin-top:0">Create a ledger entry</h2>
    {% if status.active %}
      <form method="post" action="/entries">
        <input name="message" maxlength="200" required placeholder="Enter a transaction or message">
        <button type="submit">Add record</button>
      </form>
    {% else %}
      <p>This frontend is standby. Use the repository switchover script to activate it.</p>
      <button disabled>Add record</button>
    {% endif %}
  </div>

  <div class="card" style="margin-top:20px; overflow:auto">
    <h2 style="margin-top:0">Records visible from the local database</h2>
    <table>
      <thead><tr><th>ID</th><th>Origin site</th><th>Message</th><th>Created</th></tr></thead>
      <tbody>
      {% for row in entries %}
        <tr><td>{{ row.id }}</td><td>{{ row.origin_site }}</td><td>{{ row.message }}</td><td>{{ row.created_at }}</td></tr>
      {% else %}
        <tr><td colspan="4">No records are visible yet.</td></tr>
      {% endfor %}
      </tbody>
    </table>
  </div>

  {% if status.local_error %}<div class="error">Local read error: {{ status.local_error }}</div>{% endif %}
  {% if status.write_error %}<div class="error">Write path error: {{ status.write_error }}</div>{% endif %}
  <footer>Page refreshes every 15 seconds. Database passwords are intentionally never displayed.</footer>
</main>
</body>
</html>
"""


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok", "site": SITE_ID, "role": FRONTEND_ROLE})


@app.get("/api/status")
def api_status():
    return jsonify(safe_status())


@app.route("/api/entries", methods=["GET", "POST"])
def api_entries():
    if request.method == "GET":
        try:
            return jsonify(local_entries())
        except Exception as exc:
            return jsonify({"error": str(exc)}), 503

    if FRONTEND_ROLE != "active":
        return jsonify({"error": "This frontend is standby"}), 409

    payload = request.get_json(silent=True) or {}
    message = str(payload.get("message", "")).strip()
    if not message:
        return jsonify({"error": "message is required"}), 400
    if len(message) > 200:
        return jsonify({"error": "message must be 200 characters or fewer"}), 400
    try:
        row = insert_entry(message)
        row["visible_locally"] = wait_until_local(row["id"])
        return jsonify(row), 201
    except Exception as exc:
        return jsonify({"error": str(exc)}), 503


@app.post("/entries")
def create_entry():
    if FRONTEND_ROLE != "active":
        return redirect(url_for("index", error="This frontend is standby"))
    message = request.form.get("message", "").strip()
    if not message:
        return redirect(url_for("index", error="A message is required"))
    try:
        row = insert_entry(message[:200])
        replicated = wait_until_local(row["id"])
        return redirect(url_for("index", created=row["id"], replicated="1" if replicated else "0"))
    except Exception as exc:
        return redirect(url_for("index", error=str(exc)))


@app.get("/")
def index():
    status = safe_status()
    try:
        entries = local_entries()
    except Exception:
        entries = []
    return render_template_string(
        PAGE,
        status=status,
        entries=entries,
        created=request.args.get("created"),
        replicated=request.args.get("replicated") == "1",
        error=request.args.get("error"),
    )
