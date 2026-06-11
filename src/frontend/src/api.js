import axios from 'axios'

const BASE = import.meta.env.VITE_API_URL || '/api'

export async function login(email, password) {
  const res = await axios.post(`${BASE}/login`, null, {
    auth: { username: email, password }
  })
  return res.data
}

export async function register(email, password) {
  const res = await axios.post(`${BASE}/register`, { email, password })
  return res.data
}

// Upload one or more files (each appended under "file"). Returns { batch_id, results, queued, failed }.
export async function uploadVideo(files, token) {
  const form = new FormData()
  const list = Array.isArray(files) ? files : [files]
  list.forEach((f) => form.append('file', f))
  const res = await axios.post(`${BASE}/upload`, form, {
    headers: { Authorization: `Bearer ${token}` }
  })
  return res.data
}

export async function downloadMp3(fid, token) {
  const res = await axios.get(`${BASE}/download`, {
    params: { fid },
    headers: { Authorization: `Bearer ${token}` },
    responseType: 'blob'
  })
  return res.data
}

// Count of this user's conversions completed since `since` (ISO-8601 string).
// Used by the Download bubble badge.
export async function unseenCount(token, since) {
  const res = await axios.get(`${BASE}/notifications/unseen-count`, {
    params: { since },
    headers: { Authorization: `Bearer ${token}` }
  })
  return res.data // { count }
}

// This user's converted files, newest first. Used by the My Conversions page.
export async function myFiles(token) {
  const res = await axios.get(`${BASE}/my-files`, {
    headers: { Authorization: `Bearer ${token}` }
  })
  return res.data // { files: [...] }
}

// Admin only: all users with role, signup date, and conversion count.
export async function adminUsers(token) {
  const res = await axios.get(`${BASE}/admin/users`, {
    headers: { Authorization: `Bearer ${token}` }
  })
  return res.data // [{ email, role, created_at, conversions }]
}

// Admin only: promote/demote a user between 'user' and 'admin'.
export async function setUserRole(token, email, role) {
  const res = await axios.patch(
    `${BASE}/admin/users/${encodeURIComponent(email)}`,
    { role },
    { headers: { Authorization: `Bearer ${token}` } }
  )
  return res.data
}
