CREATE TABLE IF NOT EXISTS auth_user (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email VARCHAR (255) NOT NULL UNIQUE,
    password VARCHAR (255) NOT NULL,
    role VARCHAR (32) NOT NULL DEFAULT 'user',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- SECURITY: the password column stores a bcrypt hash (NOT plaintext). The auth
-- service verifies logins with bcrypt.checkpw (constant-time) and hashes new
-- sign-ups with bcrypt.hashpw.
--
-- RBAC: every row has a role. 'admin' unlocks Dashboard/Architecture/Users in the
-- frontend and any admin-gated backend endpoint; 'user' is the default for sign-ups.
--
-- This file intentionally contains NO admin row and NO password hash — so nothing
-- secret ever lives in the (public) repo. The admin account is seeded at deploy
-- time by deploy.sh, which generates the bcrypt hash IN PostgreSQL via pgcrypto's
-- crypt()/gen_salt('bf') from the APP_LOGIN_EMAIL / APP_LOGIN_PASSWORD env vars.
-- pgcrypto bcrypt ($2a$) hashes are compatible with the auth service's bcrypt.checkpw.

-- pgcrypto provides crypt()/gen_salt() used by deploy.sh to seed the admin securely.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
