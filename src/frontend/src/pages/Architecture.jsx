import React, { useState } from 'react'

const services = [
  { id: 'client',   label: 'Browser / curl',     color: 'bg-gray-700',    desc: 'The client — uploads videos, downloads MP3s via HTTP.' },
  { id: 'frontend', label: 'Frontend (React)',    color: 'bg-blue-800',    desc: 'This web app. Served as static files by nginx on NodePort 30006. Proxies API calls to the Gateway.' },
  { id: 'gateway',  label: 'Gateway (Flask)',     color: 'bg-purple-800',  desc: 'The entry point. Handles /login, /upload, /download. Stores video in MongoDB GridFS and publishes to the video RabbitMQ queue. NodePort 30002.' },
  { id: 'auth',     label: 'Auth (Flask)',        color: 'bg-indigo-800',  desc: 'Issues and validates JWT tokens. Reads user credentials from PostgreSQL. ClusterIP only — not publicly accessible.' },
  { id: 'rabbit',   label: 'RabbitMQ',           color: 'bg-orange-800',  desc: 'The message broker. Two durable queues: "video" (uploaded videos waiting to convert) and "mp3" (converted files waiting to notify). NodePort 30004 for management UI.' },
  { id: 'converter',label: 'Converter (×4)',     color: 'bg-green-800',   desc: '4 worker pods. Each reads a video file ID from the video queue, fetches the video from MongoDB, runs ffmpeg/MoviePy to extract audio, stores the MP3 back to MongoDB, then publishes to the mp3 queue.' },
  { id: 'notify',   label: 'Notification (×2)',  color: 'bg-yellow-800',  desc: '2 worker pods. Each reads from the mp3 queue and sends an email via Gmail SMTP with the file ID for download.' },
  { id: 'mongo',    label: 'MongoDB (GridFS)',    color: 'bg-red-900',     desc: 'Stores video and MP3 files as GridFS chunks. StatefulSet for stable storage. NodePort 30005 for admin access.' },
  { id: 'postgres', label: 'PostgreSQL',         color: 'bg-blue-900',    desc: 'Stores user credentials (email + password). Used only by the Auth service. NodePort 30003 for admin access.' },
]

const arrows = [
  { from: 'client', to: 'frontend', label: 'HTTP :30006' },
  { from: 'frontend', to: 'gateway', label: 'HTTP :30002' },
  { from: 'gateway', to: 'auth', label: 'validate JWT' },
  { from: 'auth', to: 'postgres', label: 'SQL query' },
  { from: 'gateway', to: 'mongo', label: 'store video' },
  { from: 'gateway', to: 'rabbit', label: 'publish fid' },
  { from: 'rabbit', to: 'converter', label: 'consume video queue' },
  { from: 'converter', to: 'mongo', label: 'fetch video / store MP3' },
  { from: 'converter', to: 'rabbit', label: 'publish to mp3 queue' },
  { from: 'rabbit', to: 'notify', label: 'consume mp3 queue' },
  { from: 'notify', to: 'client', label: 'email with file ID' },
]

export default function Architecture() {
  const [selected, setSelected] = useState(null)
  const current = services.find(s => s.id === selected)

  return (
    <div>
      <h2 className="text-2xl font-bold text-purple-400 mb-2">System Architecture</h2>
      <p className="text-gray-400 mb-6">Click any service to learn what it does and how it connects to the rest of the system.</p>

      <div className="flex flex-wrap gap-3 mb-6">
        {services.map(s => (
          <button
            key={s.id}
            onClick={() => setSelected(s.id === selected ? null : s.id)}
            className={`px-4 py-2 rounded-lg border text-sm font-medium transition-all ${s.color}
              ${selected === s.id ? 'ring-2 ring-purple-400 scale-105' : 'border-gray-700 hover:scale-105'}`}
          >
            {s.label}
          </button>
        ))}
      </div>

      {current && (
        <div className="bg-indigo-950 border border-purple-700 rounded-xl p-5 mb-6">
          <h3 className="text-lg font-bold text-purple-300 mb-1">{current.label}</h3>
          <p className="text-gray-300">{current.desc}</p>
        </div>
      )}

      <div className="bg-gray-900 rounded-xl p-6 font-mono text-sm">
        <pre className="text-gray-300 whitespace-pre">{`
Client ──────────────────────────────────► Frontend :30006
                                                │
                                                ▼
                                        Gateway :30002
                                       /        |        \\
                                   Auth        MongoDB   RabbitMQ
                                 :5000 ──►   GridFS     "video" queue
                                   │          :30005         │
                                PostgreSQL              Converter ×4
                                  :30003            (reads video, writes MP3)
                                                          │
                                                    RabbitMQ
                                                    "mp3" queue
                                                          │
                                                   Notification ×2
                                                          │
                                                    Email → Client
`}</pre>
      </div>

      <div className="mt-6 grid grid-cols-1 md:grid-cols-2 gap-3">
        {arrows.map((a, i) => (
          <div key={i} className="bg-gray-900 rounded-lg px-4 py-2 text-sm">
            <span className="text-purple-400">{a.from}</span>
            <span className="text-gray-500 mx-2">→</span>
            <span className="text-green-400">{a.to}</span>
            <span className="text-gray-600 ml-2 text-xs">{a.label}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
