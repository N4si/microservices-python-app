# Merge-time runbook — RBAC + bcrypt (Fix 1)

**Run this WITH the operator, at the moment the `feature/rbac-and-notifications` branch is
merged to `main` and CI builds the new auth image.** It is the operational
counterpart to commit `6fd3b83`.

> This is a *tracked* operational doc (unlike the `*_EXPLAINED.md` study aids,
> which are deliberately gitignored). It contains **no credentials** — the
> Postgres password is read from the environment. Export it first from the
> gitignored `DEPLOYMENT_CONFIG.md` (`POSTGRES_PASSWORD`), never paste it here.

## Why this is needed

The new auth image (bcrypt) and the new DB schema/seed **must land together**. If
the bcrypt image rolls while live Postgres still holds the old *plaintext* row,
`bcrypt.checkpw` fails to verify against a non-hash value and **every login
fails**. (As of the F1-F hardening, a malformed stored hash now returns 401 rather
than 500 — but it's still a failed login until the DB is migrated.)

`init.sql` is **not** run by CD — it's a manual `psql`. Live Postgres has no
PersistentVolume, so re-seeding is safe and non-destructive to anything we care
about.

## Pre-flight

```bash
# Postgres password from the gitignored config — do NOT hardcode it.
export PGPASSWORD="$(grep -E '^POSTGRES_PASSWORD:' DEPLOYMENT_CONFIG.md | cut -d'"' -f2)"
# App-login plaintext (for the smoke test only), same source:
export APP_PW="$(grep -E '^APP_LOGIN_PASSWORD:' DEPLOYMENT_CONFIG.md | cut -d'"' -f2)"

kubectl config current-context        # expect arn:...:cluster/vidcast-cluster
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
echo "node: $NODE_IP"
```

## 1. Migrate the schema (idempotent, additive)

```bash
psql -h "$NODE_IP" -p 30003 -U pguser -d authdb <<'SQL'
ALTER TABLE auth_user ADD COLUMN IF NOT EXISTS role VARCHAR(32) NOT NULL DEFAULT 'user';
ALTER TABLE auth_user ADD COLUMN IF NOT EXISTS created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'auth_user_email_key') THEN
    ALTER TABLE auth_user ADD CONSTRAINT auth_user_email_key UNIQUE (email);
  END IF;
END $$;
SQL
```

## 2. Re-seed admins with bcrypt hashes (idempotent via ON CONFLICT)

```bash
psql -h "$NODE_IP" -p 30003 -U pguser -d authdb -f Helm_charts/Postgres/init.sql
```

> `init.sql` uses `CREATE TABLE IF NOT EXISTS` + `ON CONFLICT (email) DO UPDATE`,
> so running it against the now-migrated table only refreshes the two seeded
> admins' role + bcrypt hash. Any self-registered `user` rows are left untouched.

## 3. Verify the seed

```bash
psql -h "$NODE_IP" -p 30003 -U pguser -d authdb \
  -c "SELECT email, role, left(password,7) AS pw_prefix FROM auth_user;"
# expect your seeded admin email(s) as role=admin, pw_prefix = '$2b$12$'
```

## 4. Roll the auth image (CD normally does this on merge)

```bash
kubectl rollout status deployment/auth --timeout=120s
```

## 5. Smoke test — admin login carries role=admin

```bash
JWT=$(curl -s -X POST "http://$NODE_IP:30002/login" -u "admin@example.com:$APP_PW")
echo "$JWT" | cut -d. -f2 | base64 -d 2>/dev/null; echo
# expect: {"username":"admin@example.com",...,"admin":true,"role":"admin"}
```

## 6. Negative test — a new sign-up is role=user, never admin

```bash
curl -s -X POST "http://$NODE_IP:30002/register" \
  -H 'Content-Type: application/json' \
  -d '{"email":"rbac-test@example.com","password":"testpass123"}' \
  | cut -d. -f2 | base64 -d 2>/dev/null; echo
# expect: ...,"admin":false,"role":"user"
```

## Rollback

If login misbehaves: `kubectl rollout undo deployment/auth` returns the previous
(plaintext) auth image, which matches the pre-migration DB. Re-running `init.sql`
is always safe (`ON CONFLICT`). When done, `unset PGPASSWORD APP_PW`.
