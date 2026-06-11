import React, { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { myFiles, downloadMp3 } from '../api'

function formatSize(bytes) {
  if (!bytes && bytes !== 0) return '—'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

// Human-friendly date, e.g. "12 Jun 2026, 14:32".
function formatDate(iso) {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  })
}

// Status pill (queued / processing / ready / failed).
function StatusBadge({ status }) {
  const s = status || 'ready'
  const styles = {
    queued: 'bg-gray-700 text-gray-200',
    processing: 'bg-blue-900/60 text-blue-300 animate-pulse',
    ready: 'bg-green-900/50 text-green-300',
    failed: 'bg-red-900/50 text-red-300',
  }
  const labels = { queued: 'Queued', processing: 'Processing', ready: 'Ready', failed: 'Failed' }
  return (
    <span className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-semibold ${styles[s] || styles.ready}`}>
      {labels[s] || 'Ready'}
    </span>
  )
}

// Group batched files under a header row; single uploads stay inline. Input is
// already newest-first, so first-seen order is preserved.
function buildRows(files) {
  const byBatch = {}
  for (const f of files) {
    if (f.batch_id) (byBatch[f.batch_id] = byBatch[f.batch_id] || []).push(f)
  }
  const rows = []
  const seen = new Set()
  for (const f of files) {
    if (f.batch_id) {
      if (!seen.has(f.batch_id)) {
        seen.add(f.batch_id)
        const members = byBatch[f.batch_id]
        rows.push({ type: 'header', key: `h:${f.batch_id}`, created: members[0].created, count: members.length })
        members.forEach((m) => rows.push({ type: 'file', key: m.video_fid || m.fid, file: m, batched: true }))
      }
    } else {
      rows.push({ type: 'file', key: f.video_fid || f.fid, file: f, batched: false })
    }
  }
  return rows
}

export default function MyConversions({ token, onSeen }) {
  const [files, setFiles] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [downloading, setDownloading] = useState(null)

  // Visiting this page clears the nav badge.
  useEffect(() => {
    if (onSeen) onSeen()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Load, then poll every 10s while anything is queued/processing.
  useEffect(() => {
    let cancelled = false
    let timer = null

    async function load() {
      try {
        const data = await myFiles(token)
        if (cancelled) return
        const list = data?.files || []
        setFiles(list)
        setError('')
        const pending = list.some((f) => f.status === 'queued' || f.status === 'processing')
        if (pending) timer = setTimeout(load, 10000)
      } catch {
        if (!cancelled) setError('Could not load your conversions. Please try again.')
      } finally {
        if (!cancelled) setLoading(false)
      }
    }

    load()
    return () => { cancelled = true; if (timer) clearTimeout(timer) }
  }, [token])

  async function handleDownload(fid, filename) {
    setDownloading(fid)
    try {
      const blob = await downloadMp3(fid, token)
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      const base = (filename || fid).replace(/\.[^/.]+$/, '')
      a.download = `${base}.mp3`
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      setError('Download failed. The file may still be converting.')
    } finally {
      setDownloading(null)
    }
  }

  function fileRow(f, batched) {
    return (
      <tr className="border-b border-indigo-900 last:border-0 hover:bg-indigo-900/40">
        <td className={`px-4 py-3 text-gray-200 ${batched ? 'pl-8' : ''}`}>
          {batched && <span className="text-indigo-700 mr-1">└─</span>}{f.filename || f.fid}
        </td>
        <td className="px-4 py-3 text-gray-400">{formatDate(f.created)}</td>
        <td className="px-4 py-3"><StatusBadge status={f.status} /></td>
        <td className="px-4 py-3 text-gray-400">{formatSize(f.size)}</td>
        <td className="px-4 py-3 text-right">
          {f.status === 'ready' && f.fid ? (
            <button
              onClick={() => handleDownload(f.fid, f.filename)}
              disabled={downloading === f.fid}
              className="bg-purple-700 hover:bg-purple-600 disabled:opacity-50 rounded-lg px-3 py-1.5 font-semibold transition-colors"
            >
              {downloading === f.fid ? 'Downloading…' : '⬇ MP3'}
            </button>
          ) : (
            <span className="text-gray-600 text-xs">{f.status === 'failed' ? 'unavailable' : '—'}</span>
          )}
        </td>
      </tr>
    )
  }

  const rows = buildRows(files)

  return (
    <div className="max-w-3xl mx-auto mt-10">
      <h2 className="text-2xl font-bold text-purple-400 mb-2">My Conversions</h2>
      <p className="text-gray-400 mb-6">Every video you've converted, newest first. Status updates live.</p>

      {loading && <p className="text-gray-400">Loading…</p>}
      {error && <p className="text-red-400 text-sm mb-4">{error}</p>}

      {/* Empty state. */}
      {!loading && !error && files.length === 0 && (
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl p-8 text-center text-gray-400">
          <p className="mb-3">No conversions yet.</p>
          <Link
            to="/upload"
            className="inline-block bg-purple-700 hover:bg-purple-600 rounded-lg px-4 py-2 font-semibold text-white transition-colors"
          >
            Upload your first video →
          </Link>
        </div>
      )}

      {!loading && !error && files.length > 0 && (
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-gray-400 border-b border-indigo-800">
                <th className="px-4 py-3 font-medium">File</th>
                <th className="px-4 py-3 font-medium">Uploaded</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium">Audio size</th>
                <th className="px-4 py-3 font-medium text-right">Download</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) =>
                r.type === 'header' ? (
                  <tr key={r.key} className="bg-indigo-900/40 border-b border-indigo-800">
                    <td colSpan={5} className="px-4 py-2 text-xs font-semibold text-purple-300">
                      📦 Batch upload — {formatDate(r.created)} ({r.count} file{r.count > 1 ? 's' : ''})
                    </td>
                  </tr>
                ) : (
                  <React.Fragment key={r.key}>{fileRow(r.file, r.batched)}</React.Fragment>
                )
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
