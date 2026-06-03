import React, { useState, useEffect } from 'react'
import { myFiles, downloadMp3 } from '../api'

function formatSize(bytes) {
  if (!bytes && bytes !== 0) return '—'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function formatDate(iso) {
  if (!iso) return '—'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : d.toLocaleString()
}

export default function MyConversions({ token }) {
  const [files, setFiles] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [downloading, setDownloading] = useState(null)

  useEffect(() => {
    let cancelled = false
    async function load() {
      setLoading(true)
      setError('')
      try {
        const data = await myFiles(token)
        if (!cancelled) setFiles(data?.files || [])
      } catch {
        if (!cancelled) setError('Could not load your conversions. Please try again.')
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    load()
    return () => { cancelled = true }
  }, [token])

  async function handleDownload(fid) {
    setDownloading(fid)
    try {
      const blob = await downloadMp3(fid, token)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `${fid}.mp3`
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      setError('Download failed. The file may still be converting.')
    } finally {
      setDownloading(null)
    }
  }

  return (
    <div className="max-w-3xl mx-auto mt-10">
      <h2 className="text-2xl font-bold text-purple-400 mb-2">My Conversions</h2>
      <p className="text-gray-400 mb-6">Every video you've converted, newest first. Click a row to download its MP3.</p>

      {loading && <p className="text-gray-400">Loading…</p>}
      {error && <p className="text-red-400 text-sm mb-4">{error}</p>}

      {!loading && !error && files.length === 0 && (
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl p-8 text-center text-gray-400">
          <p className="mb-2">No conversions yet.</p>
          <p className="text-sm">Head to <span className="text-purple-400">Upload</span> to convert your first video.</p>
        </div>
      )}

      {!loading && !error && files.length > 0 && (
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-gray-400 border-b border-indigo-800">
                <th className="px-4 py-3 font-medium">File</th>
                <th className="px-4 py-3 font-medium">Converted</th>
                <th className="px-4 py-3 font-medium">Size</th>
                <th className="px-4 py-3 font-medium text-right">Download</th>
              </tr>
            </thead>
            <tbody>
              {files.map((f) => (
                <tr key={f.fid} className="border-b border-indigo-900 last:border-0 hover:bg-indigo-900/40">
                  <td className="px-4 py-3 font-mono text-gray-200">{f.filename || f.fid}</td>
                  <td className="px-4 py-3 text-gray-400">{formatDate(f.created)}</td>
                  <td className="px-4 py-3 text-gray-400">{formatSize(f.size)}</td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => handleDownload(f.fid)}
                      disabled={downloading === f.fid}
                      className="bg-purple-700 hover:bg-purple-600 disabled:opacity-50 rounded-lg px-3 py-1.5 font-semibold transition-colors"
                    >
                      {downloading === f.fid ? 'Downloading…' : '⬇ MP3'}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
