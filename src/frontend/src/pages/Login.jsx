import React, { useState } from 'react'
import { login, register } from '../api'

export default function Login({ onLogin }) {
  const [mode, setMode] = useState('signin') // 'signin' | 'signup'
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const isSignup = mode === 'signup'

  function switchMode() {
    setMode(isSignup ? 'signin' : 'signup')
    setError('')
    setConfirm('')
  }

  async function handleSubmit(e) {
    e.preventDefault()
    setError('')

    if (isSignup && password.length < 8) {
      setError('Password must be at least 8 characters.')
      return
    }

    if (isSignup && password !== confirm) {
      setError('Passwords do not match.')
      return
    }

    setLoading(true)
    try {
      const token = isSignup
        ? await register(email, password)
        : await login(email, password)
      onLogin(token)
    } catch (err) {
      const status = err?.response?.status
      if (isSignup && status === 409) {
        setError('An account with that email already exists.')
      } else if (isSignup) {
        setError('Could not create account. Please try again.')
      } else {
        setError('Invalid credentials. Please try again.')
      }
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="max-w-md mx-auto mt-20">
      <div className="bg-indigo-950 border border-indigo-800 rounded-xl p-8">
        <h1 className="text-3xl font-bold text-purple-400 mb-2">VidCast</h1>
        <p className="text-gray-400 mb-6">Turn video recordings into podcast-ready audio</p>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm text-gray-400 mb-1">Email</label>
            <input
              type="email"
              value={email}
              onChange={e => setEmail(e.target.value)}
              className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-purple-500"
              required
            />
          </div>
          <div>
            <label className="block text-sm text-gray-400 mb-1">Password</label>
            <input
              type="password"
              value={password}
              onChange={e => setPassword(e.target.value)}
              className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-purple-500"
              required
            />
            {isSignup && <p className="text-xs text-gray-500 mt-1">At least 8 characters.</p>}
          </div>
          {isSignup && (
            <div>
              <label className="block text-sm text-gray-400 mb-1">Confirm password</label>
              <input
                type="password"
                value={confirm}
                onChange={e => setConfirm(e.target.value)}
                className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-white focus:outline-none focus:border-purple-500"
                required
              />
            </div>
          )}
          {error && <p className="text-red-400 text-sm">{error}</p>}
          <button
            type="submit"
            disabled={loading}
            className="w-full bg-purple-700 hover:bg-purple-600 disabled:opacity-50 rounded-lg py-2 font-semibold transition-colors"
          >
            {loading
              ? (isSignup ? 'Creating account...' : 'Signing in...')
              : (isSignup ? 'Sign Up' : 'Sign In')}
          </button>
        </form>

        {isSignup && (
          <div className="mt-6 bg-indigo-900/40 border border-indigo-800 rounded-lg p-4 text-xs text-gray-400">
            <p className="font-semibold text-gray-300 mb-1">About email notifications</p>
            <p>
              When your audio conversion finishes, we'll email a download link to the
              address you sign up with — you don't need to configure anything on your
              end. Add our notification address to your contacts so it doesn't land in
              your spam folder.
            </p>
          </div>
        )}

        <p className="text-gray-400 text-sm mt-6 text-center">
          {isSignup ? 'Already have an account?' : "Don't have an account?"}{' '}
          <button
            type="button"
            onClick={switchMode}
            className="text-purple-400 hover:text-purple-300 font-semibold"
          >
            {isSignup ? 'Sign in' : 'Sign up'}
          </button>
        </p>
      </div>
    </div>
  )
}
