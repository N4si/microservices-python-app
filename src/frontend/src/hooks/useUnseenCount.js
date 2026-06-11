import { useState, useEffect } from 'react'
import { unseenCount } from '../api'

// Polls the gateway for the number of conversions completed since `since`.
// Polling (not WebSockets/SSE) is the deliberate choice for a single-user demo:
// trivially debuggable, works through any firewall, one endpoint. The few-second
// latency is irrelevant when conversion itself takes 5-30s. (If we ever needed
// thousands of concurrent users we'd switch to SSE to avoid the poll load.)
export function useUnseenCount(token, since, pollIntervalMs = 5000) {
  const [count, setCount] = useState(0)

  useEffect(() => {
    if (!token) {
      setCount(0)
      return
    }
    let cancelled = false

    const poll = async () => {
      try {
        const data = await unseenCount(token, since)
        if (!cancelled) setCount(data?.count || 0)
      } catch {
        // Silent — the next tick retries. A transient gateway blip shouldn't
        // surface an error in the navbar.
      }
    }

    poll() // immediate first read, don't wait a full interval
    const id = setInterval(poll, pollIntervalMs)
    return () => {
      cancelled = true
      clearInterval(id)
    }
  }, [token, since, pollIntervalMs])

  return count
}
