import React, { useState } from 'react'
import { Routes, Route, NavLink, Navigate } from 'react-router-dom'
import Login from './pages/Login'
import Upload from './pages/Upload'
import Download from './pages/Download'
import MyConversions from './pages/MyConversions'
import Dashboard from './pages/Dashboard'
import Architecture from './pages/Architecture'
import AdminUsers from './pages/AdminUsers'
import { userFromToken } from './auth'
import { useUnseenCount } from './hooks/useUnseenCount'

export default function App() {
  const [token, setToken] = useState(null)

  // Last time the user "saw" their downloads — drives the bubble badge. Resets on
  // login and when visiting the Download / My Conversions tabs.
  const [since, setSince] = useState(() => new Date().toISOString())
  const markDownloadsSeen = () => setSince(new Date().toISOString())

  const handleLogin = (t) => {
    markDownloadsSeen()
    setToken(t)
  }

  // Role + display name from the JWT. isAdmin gates the privileged tabs (UX only —
  // the backend enforces the real check).
  const { isAdmin, name } = userFromToken(token)

  // Count of conversions ready since `since` — the Download badge.
  const unseen = useUnseenCount(token, since)

  const nav = 'px-4 py-2 rounded hover:bg-purple-800 transition-colors'
  const active = 'bg-purple-700'

  return (
    <div className="min-h-screen flex flex-col">
      <header className="bg-indigo-950 border-b border-indigo-800 px-6 py-3 flex items-center justify-between">
        <span className="text-xl font-bold text-purple-400">🎙 VidCast</span>
        {token && (
          <nav className="flex gap-2 text-sm items-center">
            {/* Greet the signed-in user. */}
            <span className="text-gray-400 mr-2">Hi, <span className="text-purple-300 font-semibold">{name}</span></span>
            <NavLink to="/upload" className={({ isActive }) => `${nav} ${isActive ? active : ''}`}>Upload</NavLink>
            <NavLink
              to="/download"
              onClick={markDownloadsSeen}
              className={({ isActive }) => `relative ${nav} ${isActive ? active : ''}`}
            >
              Download
              {unseen > 0 && (
                <span className="absolute -top-1 -right-1 bg-red-500 text-white text-xs font-bold rounded-full px-1.5 min-w-[18px] text-center leading-tight">
                  {unseen}
                </span>
              )}
            </NavLink>
            <NavLink to="/my-files" className={({ isActive }) => `${nav} ${isActive ? active : ''}`}>My Conversions</NavLink>
            {isAdmin && <NavLink to="/dashboard" className={({ isActive }) => `${nav} ${isActive ? active : ''}`}>Dashboard</NavLink>}
            {isAdmin && <NavLink to="/architecture" className={({ isActive }) => `${nav} ${isActive ? active : ''}`}>Architecture</NavLink>}
            {isAdmin && <NavLink to="/admin/users" className={({ isActive }) => `${nav} ${isActive ? active : ''}`}>Users</NavLink>}
            <button onClick={() => setToken(null)} className={`${nav} text-red-400`}>Logout</button>
          </nav>
        )}
      </header>

      <main className="flex-1 p-6">
        <Routes>
          <Route path="/" element={token ? <Navigate to="/upload" /> : <Login onLogin={handleLogin} />} />
          <Route path="/upload" element={token ? <Upload token={token} /> : <Navigate to="/" />} />
          <Route path="/download" element={token ? <Download token={token} /> : <Navigate to="/" />} />
          {/* Visiting My Conversions also clears the nav badge. */}
          <Route path="/my-files" element={token ? <MyConversions token={token} onSeen={markDownloadsSeen} /> : <Navigate to="/" />} />
          {/* Admin-only routes. Guarded even against direct URL entry: a non-admin
              who types /dashboard is bounced to /upload, an unauth user to /. */}
          <Route
            path="/dashboard"
            element={!token ? <Navigate to="/" /> : isAdmin ? <Dashboard /> : <Navigate to="/upload" />}
          />
          <Route
            path="/architecture"
            element={!token ? <Navigate to="/" /> : isAdmin ? <Architecture /> : <Navigate to="/upload" />}
          />
          <Route
            path="/admin/users"
            element={!token ? <Navigate to="/" /> : isAdmin ? <AdminUsers token={token} /> : <Navigate to="/upload" />}
          />
        </Routes>
      </main>

      <footer className="text-center text-xs text-gray-600 py-3">
        VidCast — built on AWS EKS · React + Flask + RabbitMQ + MongoDB
      </footer>
    </div>
  )
}
