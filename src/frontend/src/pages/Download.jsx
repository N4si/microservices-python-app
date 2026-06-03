import React, { useState } from 'react'
import { downloadMp3 } from '../api'

export default function Download({ token }) {
  const [fid, setFid] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  async function handleDownload(e) {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      const blob = await downloadMp3(fid.trim(), token)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `${fid.trim()}.mp3`
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      setError('File not found or not yet converted. Check your email for the correct file ID.')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="max-w-xl mx-auto mt-10">
      <h2 className="text-2xl font-bold text-purple-400 mb-2">Download MP3</h2>
      <p className="text-gray-400 mb-6">Enter the file ID from your notification email to download your converted audio.</p>

      <form onSubmit={handleDownload} className="space-y-4">
        <div>
          <label className="block text-sm text-gray-400 mb-1">File ID</label>
          <input
            type="text"
            value={fid}
            onChange={e => setFid(e.target.value)}
            placeholder="e.g. 6a1a19f08025aee51e1d4073"
            className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-2 text-white font-mono focus:outline-none focus:border-purple-500"
            required
          />
        </div>
        {error && <p className="text-red-400 text-sm">{error}</p>}
        <button
          type="submit"
          disabled={loading || !fid.trim()}
          className="w-full bg-purple-700 hover:bg-purple-600 disabled:opacity-50 rounded-lg py-3 font-semibold transition-colors"
        >
          {loading ? 'Downloading...' : '⬇ Download MP3'}
        </button>
      </form>
    </div>
  )
}
