import sys
import os

DB_PATH    = "/root/xrumer.db"
LOG_FILE   = "/root/xrumer-traffic.log"
PID_FILE   = "/root/xrumer_mitm.pid"
XRUMER_IP  = "94.103.173.219"
PROXY_PORT = 3128
PROXY_AUTH = "test:123"

# ─────────────────────────────────────────────
# CLI MODE
# ─────────────────────────────────────────────

def cli_start(reset=False):
    if reset:
        for f in [DB_PATH, LOG_FILE]:
            if os.path.exists(f):
                os.remove(f)
                print(f"[RESET] {f} silindi")

    if os.path.exists(PID_FILE):
        with open(PID_FILE) as f:
            old_pid = f.read().strip()
        print(f"[WARN] Zaten çalışıyor (PID {old_pid}). Önce 'stop' komutunu çalıştırın.")
        return

    cmd = (
        f"nohup mitmdump "
        f"--listen-host 0.0.0.0 "
        f"--listen-port {PROXY_PORT} "
        f"--proxyauth \"{PROXY_AUTH}\" "
        f"--ssl-insecure "
        f"--set block_global=false "
        f"-q "
        f"-s {os.path.abspath(__file__)} "
        f">> {LOG_FILE} 2>&1 & echo $! > {PID_FILE}"
    )
    os.system(cmd)
    import time; time.sleep(1)
    if os.path.exists(PID_FILE):
        with open(PID_FILE) as f:
            pid = f.read().strip()
        print(f"[OK] mitmproxy başlatıldı (PID {pid})")
        print(f"[OK] Log: {LOG_FILE}")
        print(f"[OK] DB : {DB_PATH}")
    else:
        print("[ERROR] Başlatılamadı.")

def cli_stop():
    if not os.path.exists(PID_FILE):
        print("[WARN] Çalışan process bulunamadı.")
        _build_target_sites()
        return
    with open(PID_FILE) as f:
        pid = f.read().strip()
    os.system(f"kill -TERM {pid} 2>/dev/null")
    import time; time.sleep(2)
    os.remove(PID_FILE)
    print(f"[OK] PID {pid} durduruldu.")
    _build_target_sites()

def _build_target_sites():
    if not os.path.exists(DB_PATH):
        print("[WARN] DB bulunamadı, target_sites oluşturulamadı.")
        return
    import sqlite3
    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute("DROP TABLE IF EXISTS target_sites")
        conn.execute("""
            CREATE TABLE target_sites AS
            SELECT
                s.domain,
                r.url            AS action_url,
                r.body_snippet   AS form_fields,
                r.xrumer_action,
                r.step_no,
                s.final_outcome  AS status
            FROM sessions s
            JOIN requests r ON r.session_id = s.id
            WHERE s.final_outcome IN ('login_fail','reg_disabled','blocked')
              AND r.xrumer_action IN ('submit_login','submit_register','register_page','contact_form')
            ORDER BY s.domain, r.step_no
        """)
        conn.commit()
        count = conn.execute("SELECT COUNT(*) FROM target_sites").fetchone()[0]
        print(f"[OK] target_sites: {count} satır oluşturuldu → {DB_PATH}")
    except Exception as e:
        print(f"[ERROR] target_sites: {e}")
    finally:
        conn.close()

def cli_status():
    if not os.path.exists(DB_PATH):
        print("[INFO] DB yok. Henüz başlatılmamış.")
        return
    import sqlite3
    conn = sqlite3.connect(DB_PATH)
    try:
        sessions  = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        requests  = conn.execute("SELECT COUNT(*) FROM requests").fetchone()[0]
        outcomes  = conn.execute("SELECT final_outcome, COUNT(*) FROM sessions GROUP BY final_outcome ORDER BY 2 DESC").fetchall()
        targets   = 0
        try:
            targets = conn.execute("SELECT COUNT(*) FROM target_sites").fetchone()[0]
        except:
            pass
        pid_info = ""
        if os.path.exists(PID_FILE):
            with open(PID_FILE) as f:
                pid_info = f" (PID {f.read().strip()} çalışıyor)"
        print(f"\n{'─'*40}")
        print(f"  mitmproxy    : {'ÇALIŞIYOR' + pid_info if os.path.exists(PID_FILE) else 'DURDU'}")
        print(f"  Sessions     : {sessions}")
        print(f"  Requests     : {requests}")
        print(f"  Target sites : {targets}")
        print(f"{'─'*40}")
        print("  Outcome dağılımı:")
        for outcome, count in outcomes:
            print(f"    {outcome:<20} {count}")
        print(f"{'─'*40}\n")
    except Exception as e:
        print(f"[ERROR] {e}")
    finally:
        conn.close()

# ─────────────────────────────────────────────
# mitmproxy ADDON MODE
# ─────────────────────────────────────────────

import datetime, re, sqlite3, threading, atexit
from urllib.parse import urlparse

SUCCESS_KW = ["success","welcome","registered","confirm","thank you","logged in","sign up complete","account created"]
FAIL_KW    = ["error","invalid","wrong","failed","banned","already exists","not allowed","incorrect","expired","captcha"]

db_lock = threading.Lock()

def _get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""CREATE TABLE IF NOT EXISTS sessions (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        domain         TEXT,
        first_seen     TEXT,
        last_seen      TEXT,
        final_outcome  TEXT DEFAULT 'unknown',
        total_requests INTEGER DEFAULT 0
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS requests (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id      INTEGER,
        step_no         INTEGER,
        timestamp       TEXT,
        method          TEXT,
        url             TEXT,
        status_code     INTEGER,
        body_snippet    TEXT,
        redirect_to     TEXT,
        resp_success_kw TEXT,
        resp_fail_kw    TEXT,
        xrumer_action   TEXT,
        FOREIGN KEY(session_id) REFERENCES sessions(id)
    )""")
    conn.commit()
    return conn

def _get_domain(flow):
    return urlparse(flow.request.pretty_url).netloc.replace("www.","")

def _get_or_create_session(conn, domain, ts):
    row = conn.execute(
        "SELECT id FROM sessions WHERE domain=? AND date(first_seen)=date(?)", (domain, ts)
    ).fetchone()
    if row:
        return row[0]
    cur = conn.execute(
        "INSERT INTO sessions (domain, first_seen, last_seen) VALUES (?,?,?)", (domain, ts, ts)
    )
    conn.commit()
    return cur.lastrowid

def _next_step(conn, session_id):
    row = conn.execute("SELECT COUNT(*) FROM requests WHERE session_id=?", (session_id,)).fetchone()
    return (row[0] or 0) + 1

def _detect_action(method, url, body):
    ul = url.lower()
    bl = (body or "").lower()
    if method == "GET":
        if any(x in ul for x in ["login","sign_in","register","sign-in","sign-up","user","account","signup"]):
            return "register_page"
        return "discover"
    if method == "POST":
        has_pass  = any(x in bl for x in ["password","pwd","pass"])
        has_user  = any(x in bl for x in ["username","user","log","email"])
        has_name  = any(x in bl for x in ["namefirst","namelast","first_name","last_name","signup","sign_up"])
        has_cf    = any(x in bl for x in ["_wpcf7","s5_qc","contact","message","subject","fname","et_pb_contact"])
        has_email = any(x in bl for x in ["email","register","user_email","user_pass"])
        if has_pass and has_user:   return "submit_login"
        if has_name:                return "submit_register"
        if has_cf:                  return "contact_form"
        if has_email:               return "submit_register"
        return "submit_other"
    return "other"

def _determine_outcome(redirect_to, resp_fail_kw, method, status_code):
    if redirect_to:
        r = redirect_to.lower()
        if "registration=disabled" in r:
            return "reg_disabled"
        if "err=" in r or ("login" in r and method == "POST"):
            return "login_fail"
    if resp_fail_kw and method == "POST":
        if "incorrect" in resp_fail_kw or "invalid" in resp_fail_kw:
            return "login_fail"
    if status_code == 403:
        return "blocked"
    return None

def _clean_body(body_bytes):
    if not body_bytes:
        return None
    try:
        body = body_bytes.decode("utf-8", errors="replace")
    except:
        return None
    body = re.sub(r'[0-9a-f]{32,}', '[hex]', body)
    body = re.sub(r'[A-Za-z0-9+/]{60,}={0,2}', '[b64]', body)
    return body[:300]

def _log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(msg + "\n")

def _is_xrumer(flow):
    try:
        return flow.client_conn.peername[0] == XRUMER_IP
    except:
        return False

def response(flow):
    try:
        from mitmproxy import http as _http
    except ImportError:
        return

    if not _is_xrumer(flow):
        return

    ts       = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    ts_short = ts[11:]
    method   = flow.request.method
    url      = flow.request.pretty_url
    code     = flow.response.status_code
    domain   = _get_domain(flow)

    body_snippet    = _clean_body(flow.request.content) if method in ("POST","PUT","PATCH") else None
    redirect_to     = None
    resp_success_kw = None
    resp_fail_kw    = None

    if code in (301,302,303,307,308):
        redirect_to = flow.response.headers.get("location","")

    ct = flow.response.headers.get("content-type","")
    if "text/html" in ct or "application/json" in ct:
        try:
            bl = flow.response.content.decode("utf-8", errors="replace").lower()
            sk = [k for k in SUCCESS_KW if k in bl]
            fk = [k for k in FAIL_KW   if k in bl]
            if sk: resp_success_kw = ",".join(sk)
            if fk: resp_fail_kw    = ",".join(fk)
        except:
            pass

    xrumer_action = _detect_action(method, url, body_snippet)
    outcome       = _determine_outcome(redirect_to, resp_fail_kw, method, code)

    # Log dosyasına yaz
    line = f"[{ts_short}] {method} {url} → {code}"
    if redirect_to:                          line += f"\n  → {redirect_to}"
    if body_snippet and method == "POST":    line += f"\n  BODY: {body_snippet}"
    kw = []
    if resp_success_kw: kw.append(f"✓{resp_success_kw}")
    if resp_fail_kw:    kw.append(f"✗{resp_fail_kw}")
    if kw: line += f"\n  KW: {', '.join(kw)}"
    _log(line)

    # DB'ye yaz
    with db_lock:
        try:
            conn = _get_db()
            sid  = _get_or_create_session(conn, domain, ts)
            step = _next_step(conn, sid)
            conn.execute("""INSERT INTO requests
                (session_id,step_no,timestamp,method,url,status_code,
                 body_snippet,redirect_to,resp_success_kw,resp_fail_kw,xrumer_action)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (sid, step, ts_short, method, url, code,
                 body_snippet, redirect_to, resp_success_kw, resp_fail_kw, xrumer_action))
            conn.execute(
                "UPDATE sessions SET last_seen=?, total_requests=total_requests+1 WHERE id=?",
                (ts, sid)
            )
            if outcome:
                conn.execute(
                    "UPDATE sessions SET final_outcome=? WHERE id=?",
                    (outcome, sid)
                )
            conn.commit()
            conn.close()
        except Exception as e:
            _log(f"  [DB ERROR] {e}")

def done():
    _log("\n[INFO] mitmproxy kapanıyor, target_sites oluşturuluyor...")
    _build_target_sites()

atexit.register(done)

# ─────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────

if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)

    cmd = args[0]
    if cmd == "start":
        cli_start(reset="--reset" in args)
    elif cmd == "stop":
        cli_stop()
    elif cmd == "status":
        cli_status()
    else:
        print(f"Bilinmeyen komut: {cmd}")
        print("Kullanım: python3 xrumer_logger.py [start|start --reset|stop|status]")
        sys.exit(1)
