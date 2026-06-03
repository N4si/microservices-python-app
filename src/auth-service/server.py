import datetime
import os

import bcrypt
import jwt
import psycopg2
from flask import Flask, jsonify, request

server = Flask(__name__)

def get_db_connection():
    conn = psycopg2.connect(host=os.getenv('DATABASE_HOST'),
                            database=os.getenv('DATABASE_NAME'),
                            user=os.getenv('DATABASE_USER'),
                            password=os.getenv('DATABASE_PASSWORD'),
                            port=5432)
    return conn


@server.route('/healthz', methods=['GET'])
def healthz():
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify({"status": "ok"}), 200
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 503

@server.route('/login', methods=['POST'])
def login():
    auth_table_name = os.getenv('AUTH_TABLE')
    auth = request.authorization
    if not auth or not auth.username or not auth.password:
        return 'Could not verify', 401, {'WWW-Authenticate': 'Basic realm="Login required!"'}

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        # NOTE: psycopg2's cur.execute() always returns None (it does not return a
        # rowcount like some drivers), so we decide on the fetched row, not on the
        # return value of execute(). The old code branched on `res is None` and so
        # 500'd for unknown users instead of returning 401.
        query = f"SELECT email, password, role FROM {auth_table_name} WHERE email = %s"
        cur.execute(query, (auth.username,))
        user_row = cur.fetchone()
    finally:
        cur.close()
        conn.close()

    if user_row is None:
        return 'Could not verify', 401, {'WWW-Authenticate': 'Basic realm="Login required!"'}

    email, password_hash, role = user_row[0], user_row[1], user_row[2]

    # Constant-time verification against the stored bcrypt hash (see init.sql).
    # checkpw raises ValueError if the stored value is not a valid bcrypt hash
    # (e.g. a legacy plaintext row from before the bcrypt migration). Treat that
    # as an auth failure (401), never a 500 — /login must not leak a stack trace.
    try:
        password_ok = bcrypt.checkpw(auth.password.encode('utf-8'), password_hash.encode('utf-8'))
    except (ValueError, TypeError) as err:
        print(f"login: stored credential for {email} is not a valid bcrypt hash: {err}")
        password_ok = False
    if not password_ok:
        return 'Could not verify', 401, {'WWW-Authenticate': 'Basic realm="Login required!"'}

    return CreateJWT(email, os.environ['JWT_SECRET'], role)

@server.route('/register', methods=['POST'])
def register():
    auth_table_name = os.getenv('AUTH_TABLE')
    data = request.get_json(silent=True) or {}
    email = data.get('email')
    password = data.get('password')
    if not email or not password:
        return 'email and password are required', 400
    if len(password) < 8:
        return 'password must be at least 8 characters', 400

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(f"SELECT 1 FROM {auth_table_name} WHERE email = %s", (email,))
        if cur.fetchone() is not None:
            return 'an account with that email already exists', 409
        # Store a bcrypt hash, never the plaintext. New sign-ups are always role
        # 'user' — self-registration must NOT be able to mint an admin account
        # (the old code returned an admin JWT here, a privilege-escalation hole).
        hashed = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt(rounds=12)).decode('utf-8')
        cur.execute(
            f"INSERT INTO {auth_table_name} (email, password, role) VALUES (%s, %s, 'user')",
            (email, hashed),
        )
        conn.commit()
    finally:
        cur.close()
        conn.close()

    # Auto-login: return a JWT so the new user is signed in immediately, as a
    # regular (non-admin) user.
    return CreateJWT(email, os.environ['JWT_SECRET'], 'user'), 201

def CreateJWT(username, secret, role):
    return jwt.encode(
        {
            "username": username,
            "exp": datetime.datetime.now(tz=datetime.timezone.utc) + datetime.timedelta(days=1),
            "iat": datetime.datetime.now(tz=datetime.timezone.utc),
            # 'admin' (boolean) is kept for backward-compatibility with the gateway
            # and frontend that read it; 'role' (string) is the forward-compatible
            # claim that supports more roles later (auditor, support, ...).
            "admin": role == "admin",
            "role": role,
        },
        secret,
        algorithm="HS256",
    )

@server.route('/validate', methods=['POST'])
def validate():
    encoded_jwt = request.headers['Authorization']
    
    if not encoded_jwt:
        return 'Unauthorized', 401, {'WWW-Authenticate': 'Basic realm="Login required!"'}

    encoded_jwt = encoded_jwt.split(' ')[1]
    try:
        decoded_jwt = jwt.decode(encoded_jwt, os.environ['JWT_SECRET'], algorithms=["HS256"])
    except Exception:
        return 'Unauthorized', 401, {'WWW-Authenticate': 'Basic realm="Login required!"'}
    
    return decoded_jwt, 200

# --- User administration (internal, ClusterIP) ---
# These endpoints are NOT exposed via NodePort and carry NO role check of their
# own — they trust in-cluster callers, exactly like /login and /validate. The
# gateway is the component that enforces "admin only" before calling them. See
# ADMIN_USERS_EXPLAINED.md for the trust gap this implies and the real fix.

@server.route('/users', methods=['GET'])
def list_users():
    auth_table_name = os.getenv('AUTH_TABLE')
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            f"SELECT email, role, created_at FROM {auth_table_name} ORDER BY created_at"
        )
        rows = cur.fetchall()
    finally:
        cur.close()
        conn.close()

    users = [
        {
            "email": r[0],
            "role": r[1],
            "created_at": r[2].isoformat() if r[2] else None,
        }
        for r in rows
    ]
    return jsonify(users), 200

@server.route('/users/<email>', methods=['PATCH'])
def update_user_role(email):
    auth_table_name = os.getenv('AUTH_TABLE')
    data = request.get_json(silent=True) or {}
    role = data.get('role')
    if role not in ('user', 'admin'):
        return "role must be 'user' or 'admin'", 400

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            f"UPDATE {auth_table_name} SET role = %s WHERE email = %s RETURNING email, role",
            (role, email),
        )
        updated = cur.fetchone()
        conn.commit()
    finally:
        cur.close()
        conn.close()

    if updated is None:
        return 'no account with that email', 404

    return jsonify({"email": updated[0], "role": updated[1]}), 200

if __name__ == '__main__':
    server.run(host='0.0.0.0', port=5000)
