import datetime, re, sqlite3, threading, atexit
from mitmproxy import http
from urllib.parse import urlparse

DB_PATH  = "/root/xrumer.db"
LOG_FILE = "/root/xrumer-traffic.log"
XRUMER_IP = "94.103.173.219"

SUCCESS_KW = ["success","welcome","registered","confirm","thank you","logged in","sign up complete","account created"]
FAIL_KW    = ["error","invalid","wrong","failed","banned","already exists","not allowed","incorrect","expired","captcha"]

db_lock = threading.Lock()

def get_db():
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

def build_target_sites(conn):
    conn.execute("DROP TABLE IF EXISTS target_sites")
    conn.execute("""
        CREATE TABLE target_sites AS
        SELECT
            s.domain,
            r.url        AS action_url,
            r.body_snippet AS form_fields,
            r.xrumer_action,
            r.step_no,
            s.final_outcome AS status
        FROM sessions s
        JOIN requests r ON r.session_id = s.id
        WHERE s.final_outcome IN ('login_fail','reg_disabled','blocked')
          AND r.xrumer_action IN ('submit_login','submit_register','register_page','contact_form')
        ORDER BY s.domain, r.step_no
    """)
    conn.commit()

def get_domain(flow):
    return urlparse(flow.request.pretty_url).netloc.replace("www.","")

def get_or_create_session(conn, domain, ts):
    row = conn.execute("SELECT id FROM sessions WHERE domain=? AND date(first_seen)=date(?)", (domain, ts)).fetchone()
    if row:
        return row[0]
    cur = conn.execute("INSERT INTO sessions (domain, first_seen, last_seen) VALUES (?,?,?)", (domain, ts, ts))
    conn.commit()
    return cur.lastrowid

def next_step(conn, session_id):
    row = conn.execute("SELECT COUNT(*) FROM requests WHERE session_id=?", (session_id,)).fetchone()
    return (row[0] or 0) + 1

def detect_action(method, url, body):
    url_lower = url.lower()
    body_lower = (body or "").lower()
    if method == "GET":
        if any(x in url_lower for x in ["login","sign_in","register","sign-in","sign-up","user","account","signup"]):
            return "register_page"
        return "discover"
    if method == "POST":
        if any(x in body_lower for x in ["password","pwd","pass"]) and any(x in body_lower for x in ["username","user","log","email"]):
            return "submit_login"
        if any(x in body_lower for x in ["namefirst","namelast","first_name","last_name","signup","sign_up"]):
            return "submit_register"
        if any(x in body_lower for x in ["_wpcf7","s5_qc","contact","message","subject","fname","phone","et_pb_contact"]):
            return "contact_form"
        if any(x in body_lower for x in ["email","register","user_email","user_pass"]):
            return "submit_register"
        return "submit_other"
    return "other"

def determine_outcome(redirect_to, resp_fail_kw, method, url, status_code):
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

def clean_body(body_bytes):
    if not body_bytes:
        return None
    try:
        body = body_bytes.decode("utf-8", errors="replace")
    except:
        return None
    body = re.sub(r'[0-9a-f]{32,}', '[hex]', body)
    body = re.sub(r'[A-Za-z0-9+/]{60,}={0,2}', '[b64]', body)
    return body[:300]

def log(msg):
    print(msg)
    with open(LOG_FILE, "a") as f:
        f.write(msg + "\n")

def is_xrumer(flow):
    return flow.client_conn.peername[0] == XRUMER_IP

def response(flow: http.HTTPFlow):
    if not is_xrumer(flow):
        return

    ts       = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    ts_short = ts[11:]
    method   = flow.request.method
    url      = flow.request.pretty_url
    code     = flow.response.status_code
    domain   = get_domain(flow)

    body_snippet    = clean_body(flow.request.content) if method in ("POST","PUT","PATCH") else None
    redirect_to     = None
    resp_success_kw = None
    resp_fail_kw    = None

    if code in (301,302,303,307,308):
        redirect_to = flow.response.headers.get("location","")

    ct = flow.response.headers.get("content-type","")
    if "text/html" in ct or "application/json" in ct:
        try:
            body_lower = flow.response.content.decode("utf-8", errors="replace").lower()
            sk = [k for k in SUCCESS_KW if k in body_lower]
            fk = [k for k in FAIL_KW   if k in body_lower]
            if sk: resp_success_kw = ",".join(sk)
            if fk: resp_fail_kw    = ",".join(fk)
        except:
            pass

    xrumer_action = detect_action(method, url, body_snippet)
    outcome       = determine_outcome(redirect_to, resp_fail_kw, method, url, code)

    # Terminal
    log(f"[{ts_short}] {method} {url} → {code}")
    if redirect_to:   log(f"  → {redirect_to}")
    if body_snippet and method == "POST": log(f"  BODY: {body_snippet}")
    kw = []
    if resp_success_kw: kw.append(f"✓{resp_success_kw}")
    if resp_fail_kw:    kw.append(f"✗{resp_fail_kw}")
    if kw: log(f"  KW: {', '.join(kw)}")

    # DB
    with db_lock:
        try:
            conn = get_db()
            sid  = get_or_create_session(conn, domain, ts)
            step = next_step(conn, sid)
            conn.execute("""INSERT INTO requests
                (session_id,step_no,timestamp,method,url,status_code,
                 body_snippet,redirect_to,resp_success_kw,resp_fail_kw,xrumer_action)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (sid,step,ts_short,method,url,code,
                 body_snippet,redirect_to,resp_success_kw,resp_fail_kw,xrumer_action))
            conn.execute("UPDATE sessions SET last_seen=?, total_requests=total_requests+1 WHERE id=?", (ts,sid))
            if outcome:
                conn.execute("UPDATE sessions SET final_outcome=? WHERE id=?", (outcome,sid))
            conn.commit()
            conn.close()
        except Exception as e:
            log(f"  [DB ERROR] {e}")

def done():
    log("\n[INFO] mitmproxy kapanıyor, target_sites tablosu oluşturuluyor...")
    try:
        conn = get_db()
        build_target_sites(conn)
        count = conn.execute("SELECT COUNT(*) FROM target_sites").fetchone()[0]
        conn.close()
        log(f"[INFO] target_sites: {count} satır oluşturuldu → /root/xrumer.db")
    except Exception as e:
        log(f"[ERROR] target_sites oluşturulamadı: {e}")

atexit.register(done)
