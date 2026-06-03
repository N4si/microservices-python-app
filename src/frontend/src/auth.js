// Decode a JWT payload WITHOUT verifying the signature.
// The gateway (via the auth service /validate) is the real authority — it
// cryptographically verifies the token on every protected request. The frontend
// only needs to *read* claims to decide what to show, so an unverified decode is
// fine here: a tampered token buys nothing because the backend rejects it anyway.
export function decodeJwt(token) {
  if (!token) return null
  try {
    const payload = token.split('.')[1]
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/')
    const json = decodeURIComponent(
      atob(base64)
        .split('')
        .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
        .join('')
    )
    return JSON.parse(json)
  } catch {
    return null
  }
}

// Convenience: derive the user view-model from a raw token string.
export function userFromToken(token) {
  const claims = decodeJwt(token)
  return {
    email: claims?.username || null,
    role: claims?.role || 'anonymous',
    // Read the backward-compatible boolean; fall back to role string.
    isAdmin: claims?.admin === true || claims?.role === 'admin',
    isAuthenticated: Boolean(claims),
  }
}
