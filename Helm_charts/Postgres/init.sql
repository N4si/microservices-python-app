CREATE TABLE IF NOT EXISTS auth_user (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email VARCHAR (255) NOT NULL UNIQUE,
    password VARCHAR (255) NOT NULL,
    role VARCHAR (32) NOT NULL DEFAULT 'user',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- SECURITY: the password column stores a bcrypt hash (NOT plaintext). The auth
-- service verifies logins with bcrypt.checkpw (constant-time) and hashes new
-- sign-ups with bcrypt.hashpw. The hashes below were generated locally from the
-- plaintext in DEPLOYMENT_CONFIG.md (gitignored) — only the hashes are committed,
-- never the plaintext. Regenerate with:
--   python3 -c "import bcrypt; print(bcrypt.hashpw(b'<plaintext>', bcrypt.gensalt(rounds=12)).decode())"
--
-- RBAC: every row has a role. 'admin' unlocks Dashboard/Architecture/Users in the
-- frontend and any admin-gated backend endpoint; 'user' is the default for sign-ups.

-- Seed admin accounts. ON CONFLICT makes this re-runnable on cluster rebuilds:
-- re-applying init.sql resets the seeded admins' role + password hash without
-- erroring on the UNIQUE(email) constraint.
INSERT INTO auth_user (email, password, role)
VALUES ('baabalola@gmail.com', '$2b$12$27w9I7SBkuawEIE9Is/nAennwQNfo16nwz.yQbuYBGUHIj4JUCs.6', 'admin')
ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, password = EXCLUDED.password;

INSERT INTO auth_user (email, password, role)
VALUES ('johnbsignups@gmail.com', '$2b$12$UAKcprFDrJ9bH84OSCjkXOXzJcARL.K1qIaiGl.casOtTtBeGjR76', 'admin')
ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, password = EXCLUDED.password;
