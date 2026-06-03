import React from 'react'

const GRAFANA_URL = import.meta.env.VITE_GRAFANA_URL || 'http://localhost:30007'

export default function Dashboard() {
  return (
    <div>
      <h2 className="text-2xl font-bold text-purple-400 mb-2">Operations Dashboard</h2>
      <p className="text-gray-400 mb-6">
        Live Grafana dashboard showing pod health, node resources, and RabbitMQ queue depth.
      </p>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl p-4">
          <h3 className="text-purple-400 font-semibold mb-1">Access Grafana</h3>
          <p className="text-gray-400 text-sm mb-2">Full dashboard with all metrics</p>
          <a
            href={`${GRAFANA_URL}/d/vidcast-ops`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-purple-400 underline text-sm hover:text-purple-300"
          >
            Open Grafana → VidCast Operations
          </a>
          <p className="text-gray-600 text-xs mt-1">Credentials: admin / vidcast-demo</p>
        </div>
        <div className="bg-indigo-950 border border-indigo-800 rounded-xl p-4">
          <h3 className="text-purple-400 font-semibold mb-1">Access Alertmanager</h3>
          <p className="text-gray-400 text-sm mb-2">View active alerts</p>
          <a
            href={GRAFANA_URL.replace('30007', '30008')}
            target="_blank"
            rel="noopener noreferrer"
            className="text-purple-400 underline text-sm hover:text-purple-300"
          >
            Open Alertmanager
          </a>
        </div>
      </div>

      <div className="bg-indigo-950 border border-indigo-800 rounded-xl overflow-hidden">
        <iframe
          src={`${GRAFANA_URL}/d/vidcast-ops?orgId=1&kiosk=tv`}
          className="w-full h-96"
          title="VidCast Operations Dashboard"
        />
      </div>
    </div>
  )
}
