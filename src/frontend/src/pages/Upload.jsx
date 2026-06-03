import React, { useState, useRef } from 'react'
import { uploadVideo } from '../api'

export default function Upload({ token }) {
  const [file, setFile] = useState(null)
  const [status, setStatus] = useState(null)
  const [loading, setLoading] = useState(false)
  const [dragging, setDragging] = useState(false)
  const inputRef = useRef()

  function handleDrop(e) {
    e.preventDefault()
    setDragging(false)
    const f = e.dataTransfer.files[0]
    if (f && f.type.startsWith('video/')) setFile(f)
  }

  async function handleUpload() {
    if (!file) return
    setLoading(true)
    setStatus(null)
    try {
      await uploadVideo(file, token)
      setStatus({ type: 'success', message: "Your video is being processed. You'll receive an email when the MP3 is ready to download." })
      setFile(null)
    } catch (err) {
      setStatus({ type: 'error', message: err.response?.data || 'Upload failed. Please try again.' })
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="max-w-xl mx-auto mt-10">
      <h2 className="text-2xl font-bold text-purple-400 mb-2">Upload Video</h2>
      <p className="text-gray-400 mb-6">Upload an MP4 file. We'll extract the audio and email you a download link.</p>

      <div
        onDragOver={e => { e.preventDefault(); setDragging(true) }}
        onDragLeave={() => setDragging(false)}
        onDrop={handleDrop}
        onClick={() => inputRef.current?.click()}
        className={`border-2 border-dashed rounded-xl p-12 text-center cursor-pointer transition-colors
          ${dragging ? 'border-purple-400 bg-purple-900/20' : 'border-gray-700 hover:border-gray-500'}`}
      >
        <input ref={inputRef} type="file" accept="video/*" className="hidden" onChange={e => setFile(e.target.files[0])} />
        {file
          ? <p className="text-purple-300">📹 {file.name} ({(file.size / 1e6).toFixed(1)} MB)</p>
          : <p className="text-gray-500">Drag & drop a video file, or click to browse</p>
        }
      </div>

      {file && (
        <button
          onClick={handleUpload}
          disabled={loading}
          className="mt-4 w-full bg-purple-700 hover:bg-purple-600 disabled:opacity-50 rounded-lg py-3 font-semibold transition-colors"
        >
          {loading ? 'Uploading...' : 'Convert to MP3'}
        </button>
      )}

      {status && (
        <div className={`mt-4 p-4 rounded-lg ${status.type === 'success' ? 'bg-green-900/40 text-green-300' : 'bg-red-900/40 text-red-300'}`}>
          {status.message}
        </div>
      )}
    </div>
  )
}
