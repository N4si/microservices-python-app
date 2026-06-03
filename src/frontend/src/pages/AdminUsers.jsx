import React, { useState, useEffect } from 'react'
import { adminUsers, setUserRole } from '../api'
import { userFromToken } from '../auth'

function formatDate(iso) {
  if (!iso) return '—'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleDateString()
}

export default function AdminUsers({ token }) {
  const me = userFromToken(token).email
  const [users, setUsers] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(null) // email currently being changed

  async function load() {
    setError('')
    try {
      const data = await adminUsers(token)
      setUsers(Array.isArray(data) ? data : [])
    } catch {
      setError('Could not load users.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    adminUsers(token)
      .then((data) => { if (!cancelled) setUsers(Array.isArray(data) ? data : []) })
      .catch(() => { if (!cancelled) setError('Could not load users.') })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [token])

  async function changeRole(email, nextRole) {
    setBusy(email)
    setError('')
    try {
      await setUserRole(token, email, nextRole)
      await load()
    } catch (err) {
      const status = err?.response?.status
      const msg =
        status === 403 ? 'You cannot change your own role.'
        : status === 409 ? 'Cannot demote the last remaining admin.'
        : status === 404 ? 'That account no longer exists.'
        : 'Could not update role.'
      setError(msg)
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="max-w-4xl mx-auto mt-10">
      <h2 className="text-2xl font-bold text-purple-400 mb-2">Users</h2>
      <p className="text-gray-400 mb-6">Manage roles. Admins can access the Dashboard, Architecture, and this page.</p>

      {loading && <p className="text-gray-400">Loading…</p>}
      {error && <p className="text-red-400 text-sm mb-4">{error}</p>}

      {!loading && (
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-gray-400 border-b border-indigo-800">
                <th className="px-4 py-3 font-medium">Email</th>
                <th className="px-4 py-3 font-medium">Role</th>
                <th className="px-4 py-3 font-medium">Signed up</th>
                <th className="px-4 py-3 font-medium">Conversions</th>
                <th className="px-4 py-3 font-medium text-right">Action</th>
              </tr>
            </thead>
            <tbody>
              {users.map((u) => {
                const isMe = u.email === me
                const isAdmin = u.role === 'admin'
                const nextRole = isAdmin ? 'user' : 'admin'
                return (
                  <tr key={u.email} className="border-b border-indigo-900 last:border-0 hover:bg-indigo-900/40">
                    <td className="px-4 py-3 text-gray-200">
                      {u.email}{isMe && <span className="text-gray-500"> (you)</span>}
                    </td>
                    <td className="px-4 py-3">
                      <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${isAdmin ? 'bg-purple-700 text-white' : 'bg-gray-700 text-gray-200'}`}>
                        {u.role}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-gray-400">{formatDate(u.created_at)}</td>
                    <td className="px-4 py-3 text-gray-400">{u.conversions ?? 0}</td>
                    <td className="px-4 py-3 text-right">
                      <button
                        onClick={() => changeRole(u.email, nextRole)}
                        disabled={isMe || busy === u.email}
                        title={isMe ? "You can't change your own role" : ''}
                        className="bg-purple-700 hover:bg-purple-600 disabled:opacity-40 disabled:cursor-not-allowed rounded-lg px-3 py-1.5 font-semibold transition-colors"
                      >
                        {busy === u.email ? '…' : isAdmin ? 'Demote to user' : 'Promote to admin'}
                      </button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
