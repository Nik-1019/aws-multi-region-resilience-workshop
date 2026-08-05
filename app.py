#!/usr/bin/env python3
"""
AWS Multi-Region Resilience Workshop -- demo application.

Renders a dashboard showing which AWS region, availability zone and instance is
currently serving the request, plus live database connectivity information.
Participants watch this page while a region is deliberately broken so they can
see failover happen in real time.

Everything degrades gracefully: no instance metadata means "Local Development"
mode, no database means the UI flips to DEGRADED instead of throwing a 500.
"""

import logging
import os
import re
import threading
import time
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify, render_template

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_NAME = os.environ.get("DB_NAME", "workshop")
DB_USER = os.environ.get("DB_USER", "admin")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_ENGINE = os.environ.get("DB_ENGINE", "mysql").strip().lower()
PRIMARY_REGION = os.environ.get("PRIMARY_REGION", "us-east-1")
APP_PORT = int(os.environ.get("APP_PORT", "80"))

# Footer credit + cost estimate. Both are cosmetic; override per workshop.
WORKSHOP_AUTHOR = os.environ.get("WORKSHOP_AUTHOR", "nyx - cajayon.nikko01@gmail.com")
ESTIMATED_HOURLY_COST = os.environ.get("ESTIMATED_HOURLY_COST", "$0.18/hr")

# Anything that talks to the network gets a short leash -- a page render must
# never hang because a database in another region went away.
DB_CONNECT_TIMEOUT = float(os.environ.get("DB_CONNECT_TIMEOUT", "3"))
IMDS_TIMEOUT = float(os.environ.get("IMDS_TIMEOUT", "1"))
IMDS_BASE = "http://169.254.169.254/latest"

START_TIME = time.time()
START_DATETIME = datetime.now(timezone.utc)

LOCAL_PLACEHOLDER = {
    "region": "local-dev",
    "az": "local-dev-a",
    "instance_id": "i-localdevelopment",
    "instance_type": "n/a",
    "available": False,
}

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)-8s %(message)s",
)
log = logging.getLogger("resilience-workshop")

app = Flask(__name__)


# --------------------------------------------------------------------------
# Database drivers -- both engines are optional imports so the app still boots
# (in DEGRADED mode) if only one driver is installed on the box.
# --------------------------------------------------------------------------

try:
    import mysql.connector as mysql_driver
except ImportError:  # pragma: no cover - depends on install profile
    mysql_driver = None

try:
    import psycopg2 as pg_driver
except ImportError:  # pragma: no cover - depends on install profile
    pg_driver = None


def _is_postgres():
    return DB_ENGINE in ("postgres", "postgresql", "psql")


def _driver_available():
    return pg_driver is not None if _is_postgres() else mysql_driver is not None


def db_connect():
    """Open a short-lived connection. Raises on any failure."""
    if not DB_PASSWORD:
        raise RuntimeError("DB_PASSWORD is not set")
    if not _driver_available():
        raise RuntimeError(
            "no driver installed for DB_ENGINE=%s (pip install -r requirements.txt)"
            % DB_ENGINE
        )

    if _is_postgres():
        return pg_driver.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            connect_timeout=int(DB_CONNECT_TIMEOUT),
        )

    # Both drivers insist on an int timeout; a float raises TypeError before a
    # connection is even attempted.
    return mysql_driver.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connection_timeout=int(DB_CONNECT_TIMEOUT),
    )


CREATE_TABLE_MYSQL = (
    "CREATE TABLE IF NOT EXISTS health_check ("
    "  id INT AUTO_INCREMENT PRIMARY KEY,"
    "  checked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
    ")"
)

CREATE_TABLE_POSTGRES = (
    "CREATE TABLE IF NOT EXISTS health_check ("
    "  id SERIAL PRIMARY KEY,"
    "  checked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
    ")"
)


def ensure_schema():
    """
    Create health_check on startup. Failing here is expected and harmless on a
    read replica -- the table arrives via replication from the primary.
    """
    try:
        conn = db_connect()
    except Exception as exc:
        log.warning("schema init skipped, database unreachable: %s", exc)
        return

    try:
        cur = conn.cursor()
        cur.execute(CREATE_TABLE_POSTGRES if _is_postgres() else CREATE_TABLE_MYSQL)
        conn.commit()
        cur.close()
        log.info("health_check table is ready")
    except Exception as exc:
        log.warning("schema init failed (read replica?): %s", exc)
    finally:
        _close_quietly(conn)


def _close_quietly(conn):
    try:
        conn.close()
    except Exception:
        pass


_READ_ONLY_MARKERS = (
    "read only",
    "read-only",
    "--read-only",
    "readonly",
    "in recovery",
    "cannot execute insert",
    "cannot execute delete",
)


def _looks_read_only(exc):
    return any(marker in str(exc).lower() for marker in _READ_ONLY_MARKERS)


def _extract_version(raw):
    """
    Pull a version number out of SELECT VERSION().

    MySQL answers '8.0.36'; PostgreSQL answers 'PostgreSQL 16.3 on x86_64...'.
    Return the first dotted-number token either way.
    """
    match = re.search(r"\d+\.\d+(?:\.\d+)?", raw)
    return match.group(0) if match else raw.split()[0][:32]


def probe_database():
    """
    One full round trip against the database.

    Writes a timestamp into health_check and reads it back, timing the pair.
    If the write is rejected because the instance is a read replica we fall
    back to a read-only probe and report the mode accordingly.
    """
    result = {
        "connected": False,
        "mode": "unknown",
        "latency_ms": None,
        "engine": DB_ENGINE,
        "engine_version": None,
        "host": DB_HOST,
        "error": None,
        "rows": None,
    }

    conn = None
    try:
        conn = db_connect()
        cur = conn.cursor()

        cur.execute("SELECT VERSION()")
        version_row = cur.fetchone()
        if version_row:
            result["engine_version"] = _extract_version(str(version_row[0]))

        started = time.perf_counter()
        try:
            cur.execute("INSERT INTO health_check (checked_at) VALUES (%s)",
                        (datetime.now(timezone.utc).replace(tzinfo=None),))
            conn.commit()
            cur.execute("SELECT id, checked_at FROM health_check "
                        "ORDER BY id DESC LIMIT 1")
            cur.fetchone()
            result["latency_ms"] = round((time.perf_counter() - started) * 1000, 1)
            result["mode"] = "read-write"
            _maybe_prune(conn, cur)
        except Exception as write_exc:
            _rollback_quietly(conn)
            if not _looks_read_only(write_exc):
                raise
            # Replica: time a read instead so the card still shows latency.
            started = time.perf_counter()
            cur.execute("SELECT id, checked_at FROM health_check "
                        "ORDER BY id DESC LIMIT 1")
            cur.fetchone()
            result["latency_ms"] = round((time.perf_counter() - started) * 1000, 1)
            result["mode"] = "read-only"

        try:
            cur.execute("SELECT COUNT(*) FROM health_check")
            count_row = cur.fetchone()
            if count_row:
                result["rows"] = int(count_row[0])
        except Exception:
            _rollback_quietly(conn)

        result["connected"] = True
        cur.close()
    except Exception as exc:
        result["error"] = str(exc).strip().splitlines()[0][:200] if str(exc) else \
            exc.__class__.__name__
        log.warning("database probe failed: %s", result["error"])
    finally:
        if conn is not None:
            _close_quietly(conn)

    return result


def _rollback_quietly(conn):
    try:
        conn.rollback()
    except Exception:
        pass


_prune_counter = {"n": 0}
_prune_lock = threading.Lock()


def _maybe_prune(conn, cur):
    """Trim the table every 200 writes so a long workshop cannot fill the disk."""
    with _prune_lock:
        _prune_counter["n"] += 1
        due = _prune_counter["n"] % 200 == 0
    if not due:
        return
    try:
        if _is_postgres():
            cur.execute("DELETE FROM health_check "
                        "WHERE checked_at < NOW() - INTERVAL '2 hours'")
        else:
            cur.execute("DELETE FROM health_check "
                        "WHERE checked_at < DATE_SUB(NOW(), INTERVAL 2 HOUR)")
        conn.commit()
    except Exception:
        _rollback_quietly(conn)


# --------------------------------------------------------------------------
# EC2 Instance Metadata Service (IMDSv2)
# --------------------------------------------------------------------------

_metadata_cache = {"value": None, "fetched_at": 0.0}
_metadata_lock = threading.Lock()
METADATA_TTL = 300  # instance identity never changes; re-probe occasionally


def _fetch_metadata():
    """Query IMDSv2. Returns placeholder values when the service is absent."""
    try:
        token = requests.put(
            IMDS_BASE + "/api/token",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"},
            timeout=IMDS_TIMEOUT,
        )
        token.raise_for_status()
        headers = {"X-aws-ec2-metadata-token": token.text}

        def get(path, default="unknown"):
            resp = requests.get(IMDS_BASE + "/meta-data/" + path,
                                headers=headers, timeout=IMDS_TIMEOUT)
            return resp.text.strip() if resp.status_code == 200 else default

        az = get("placement/availability-zone")
        return {
            "region": get("placement/region", az[:-1] if az != "unknown" else "unknown"),
            "az": az,
            "instance_id": get("instance-id"),
            "instance_type": get("instance-type"),
            "available": True,
        }
    except Exception as exc:
        log.debug("IMDS unavailable, using local development values: %s", exc)
        return dict(LOCAL_PLACEHOLDER)


def get_metadata():
    now = time.time()
    with _metadata_lock:
        cached = _metadata_cache["value"]
        fresh = cached is not None and (now - _metadata_cache["fetched_at"]) < METADATA_TTL
        # Never cache a failed lookup for long -- metadata may just be slow to
        # come up while the instance is still booting.
        if fresh and cached.get("available"):
            return dict(cached)

    value = _fetch_metadata()
    with _metadata_lock:
        _metadata_cache["value"] = value
        _metadata_cache["fetched_at"] = now
    return dict(value)


# --------------------------------------------------------------------------
# Failover detection (in-memory, per worker process)
# --------------------------------------------------------------------------

_topology = {
    "region": None,
    "db_mode": None,
    "last_failover": None,     # ISO-8601 UTC string
    "last_failover_event": None,
}
_topology_lock = threading.Lock()


def record_topology(region, db_mode):
    """
    Note the serving region and database mode; if either changes between two
    observations, treat that as a failover and stamp the time.

    A region change means traffic moved. A read-only -> read-write flip means a
    replica was promoted. Both are the moment participants are watching for.
    """
    with _topology_lock:
        previous_region = _topology["region"]
        previous_mode = _topology["db_mode"]
        event = None

        if previous_region is not None and region != previous_region:
            event = "Region changed: %s -> %s" % (previous_region, region)
        elif (previous_mode == "read-only" and db_mode == "read-write"):
            event = "Database promoted to read-write"

        if event:
            _topology["last_failover"] = datetime.now(timezone.utc).isoformat(
                timespec="seconds")
            _topology["last_failover_event"] = event
            log.warning("FAILOVER DETECTED -- %s", event)

        _topology["region"] = region
        # Only remember a definite mode, so a blip of "unknown" during an
        # outage does not fabricate a promotion event on recovery.
        if db_mode in ("read-write", "read-only"):
            _topology["db_mode"] = db_mode

        return _topology["last_failover"], _topology["last_failover_event"]


# --------------------------------------------------------------------------
# Status assembly
# --------------------------------------------------------------------------

def human_uptime(seconds):
    seconds = int(seconds)
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    if days:
        return "%dd %dh %dm" % (days, hours, minutes)
    if hours:
        return "%dh %dm %ds" % (hours, minutes, secs)
    if minutes:
        return "%dm %ds" % (minutes, secs)
    return "%ds" % secs


def build_status():
    """Single source of truth for the UI, /api/status and /health."""
    meta = get_metadata()
    db = probe_database()
    last_failover, last_failover_event = record_topology(meta["region"], db["mode"])

    if not meta["available"]:
        state = "local"
        state_label = "LOCAL DEVELOPMENT"
    elif not db["connected"]:
        state = "degraded"
        state_label = "DEGRADED"
    elif meta["region"] == PRIMARY_REGION:
        state = "primary"
        state_label = "PRIMARY REGION"
    else:
        state = "secondary"
        state_label = "SECONDARY REGION"

    uptime_seconds = int(time.time() - START_TIME)

    return {
        "state": state,
        "state_label": state_label,
        "region": meta["region"],
        "primary_region": PRIMARY_REGION,
        "az": meta["az"],
        "instance_id": meta["instance_id"],
        "instance_type": meta["instance_type"],
        "metadata_available": meta["available"],
        "db": "connected" if db["connected"] else "disconnected",
        "db_mode": db["mode"],
        "db_engine": db["engine"],
        "db_engine_version": db["engine_version"],
        "db_host": db["host"],
        "db_latency_ms": db["latency_ms"],
        "db_rows": db["rows"],
        "db_error": db["error"],
        "uptime_seconds": uptime_seconds,
        "uptime_human": human_uptime(uptime_seconds),
        "started_at": START_DATETIME.isoformat(timespec="seconds"),
        "last_failover": last_failover,
        "last_failover_event": last_failover_event,
        "server_time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "hourly_cost": ESTIMATED_HOURLY_COST,
        "author": WORKSHOP_AUTHOR,
    }


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

@app.route("/")
def index():
    return render_template("index.html", data=build_status())


@app.route("/api/status")
def api_status():
    response = jsonify(build_status())
    response.headers["Cache-Control"] = "no-store, max-age=0"
    return response


@app.route("/health")
def health():
    """
    Load balancer health check. Always 200 while the process can serve: the ALB
    must not pull an instance out of service just because its replica is
    read-only, otherwise the secondary region can never take traffic.
    """
    status = build_status()
    response = jsonify({
        "status": "healthy",
        "region": status["region"],
        "az": status["az"],
        "db": status["db"],
        "db_mode": status["db_mode"],
        "uptime_seconds": status["uptime_seconds"],
    })
    response.headers["Cache-Control"] = "no-store, max-age=0"
    return response


@app.errorhandler(500)
def internal_error(error):  # pragma: no cover - safety net
    log.exception("unhandled error: %s", error)
    return jsonify({"status": "error", "message": "internal server error"}), 500


# Startup work runs at import time so it also happens under gunicorn.
ensure_schema()

if __name__ == "__main__":
    log.info("starting on port %s (engine=%s, primary=%s)",
             APP_PORT, DB_ENGINE, PRIMARY_REGION)
    app.run(host="0.0.0.0", port=APP_PORT, debug=False)
