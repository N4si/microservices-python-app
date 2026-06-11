import React, { useState, useRef } from 'react'
import { Link } from 'react-router-dom'
import { uploadVideo } from '../api'

const MAX_BATCH = 20

function formatSize(bytes) {
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1e6).toFixed(1)} MB`
  return `${(bytes / 1e9).toFixed(2)} GB`
}

export default function Upload({ token }) {
  const [files, setFiles] = useState([])
  const [status, setStatus] = useState(null)
  const [loading, setLoading] = useState(false)
  const [dragging, setDragging] = useState(false)
  const inputRef = useRef()

  // Add files to the selection (de-duped by name+size), capped at MAX_BATCH.
  function addFiles(fileList) {
    const incoming = Array.from(fileList).filter((f) => f.type.startsWith('video/'))
    if (incoming.length === 0) return
    setStatus(null)
    setFiles((prev) => {
      const seen = new Set(prev.map((f) => `${f.name}:${f.size}`))
      const merged = [...prev]
      for (const f of incoming) {
        const key = `${f.name}:${f.size}`
        if (!seen.has(key)) { seen.add(key); merged.push(f) }
      }
      return merged.slice(0, MAX_BATCH)
    })
  }

  function removeFile(idx) {
    setFiles((prev) => prev.filter((_, i) => i !== idx))
  }

  function handleDrop(e) {
    e.preventDefault()
    setDragging(false)
    addFiles(e.dataTransfer.files)
  }

  async function handleUpload() {
    if (files.length === 0) return
    setLoading(true)
    setStatus(null)
    const count = files.length
    try {
      const data = await uploadVideo(files, token)
      setStatus({ type: 'success', count, queued: data?.queued ?? count, failed: data?.failed ?? 0 })
      setFiles([])
    } catch (err) {
      setStatus({ type: 'error', message: err.response?.data?.error || err.response?.data || 'Upload failed. Please try again.' })
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="max-w-xl mx-auto mt-10">
      <h2 className="text-2xl font-bold text-purple-400 mb-2">Upload Video</h2>
      <p className="text-gray-400 mb-6">Upload one or more video files. We'll extract the audio and email you when they're ready.</p>

      <div
        onDragOver={e => { e.preventDefault(); setDragging(true) }}
        onDragLeave={() => setDragging(false)}
        onDrop={handleDrop}
        onClick={() => inputRef.current?.click()}
        className={`border-2 border-dashed rounded-xl p-12 text-center cursor-pointer transition-colors
          ${dragging ? 'border-purple-400 bg-purple-900/20' : 'border-gray-700 hover:border-gray-500'}`}
      >
        <input
          ref={inputRef}
          type="file"
          multiple
          accept="video/*,.mp4,.mov,.mkv,.avi,.webm,.m4v"
          className="hidden"
          onChange={e => addFiles(e.target.files)}
        />
        <p className="text-gray-500">Drag & drop video files, or click to browse</p>
      </div>

      {/* Batch guidance + accepted formats and the real size limit (256MB — frontend nginx). */}
      <p className="text-gray-500 text-xs mt-3">Up to {MAX_BATCH} files per batch — you'll get one email when the whole batch is ready.</p>
      <p className="text-gray-500 text-xs mt-1">Accepts MP4, MOV, MKV, AVI, WebM, M4V · Maximum 256MB per file</p>

      {/* Selected files, with per-file remove. */}
      {files.length > 0 && (
        <div className="mt-4 bg-indigo-950 border border-indigo-800 rounded-xl divide-y divide-indigo-900">
          {files.map((f, i) => (
            <div key={`${f.name}:${f.size}`} className="flex items-center justify-between px-4 py-2 text-sm">
              <span className="text-purple-300 truncate mr-3">📹 {f.name}</span>
              <span className="text-gray-500 whitespace-nowrap mr-3">{formatSize(f.size)}</span>
              <button
                onClick={() => removeFile(i)}
                className="text-gray-500 hover:text-red-400 font-bold"
                aria-label={`Remove ${f.name}`}
              >×</button>
            </div>
          ))}
        </div>
      )}

      {files.length > 0 && (
        <button
          onClick={handleUpload}
          disabled={loading}
          className="mt-4 w-full bg-purple-700 hover:bg-purple-600 disabled:opacity-50 rounded-lg py-3 font-semibold transition-colors"
        >
          {loading ? 'Uploading...' : `Upload ${files.length} file${files.length > 1 ? 's' : ''}`}
        </button>
      )}

      {/* Upload confirmation. */}
      {status?.type === 'success' && (
        <div className="mt-4 p-4 rounded-lg bg-green-900/40 text-green-300">
          <p className="font-semibold">
            {status.queued} file{status.queued > 1 ? 's' : ''} queued for conversion.
            {status.failed > 0 && ` (${status.failed} could not be accepted.)`}
          </p>
          <p className="text-sm mt-1">
            {status.count > 1
              ? "You'll receive one email when the whole batch is ready."
              : "You'll receive an email when your audio is ready."}
          </p>
          <p className="text-sm mt-1">
            Track progress on the{' '}
            <Link to="/my-files" className="underline text-green-200 hover:text-green-100">My Conversions</Link> page.
          </p>
        </div>
      )}
      {status?.type === 'error' && (
        <div className="mt-4 p-4 rounded-lg bg-red-900/40 text-red-300">{status.message}</div>
      )}
    </div>
  )
}
