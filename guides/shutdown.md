# Graceful Shutdown

nova_resilience provides ordered graceful shutdown that coordinates with Kubernetes load balancers and Nova's HTTP connection draining.

## How it works

When the BEAM receives SIGTERM (or the application stops), the shutdown sequence is:

```
1. nova_resilience prep_stop (automatic)
   |
   +-- Mark not-ready (/ready returns 503)
   |   Emits [nova_resilience, gate, not_ready]
   |
   +-- Wait shutdown_delay (default 5s)
   |   Load balancer detects not-ready, stops routing traffic
   |
   +-- For each priority group (ascending 0, 1, 2, ...):
   |     +-- Drain in-flight requests (monitors bulkhead occupancy)
   |     +-- Delete bulkheads
   |     +-- Delete circuit breakers
   |     +-- Run adapter shutdown (e.g. brod:stop_client)
   |     +-- Unregister health checks
   |
   +-- Emits [nova_resilience, shutdown, stop] with duration
   |
   +-- Done

2. Nova prep_stop
   |
   +-- Suspend listener (stop accepting connections)
   +-- Drain active HTTP connections (default 15s)
   +-- Stop listener
```

## Shutdown is automatic

nova_resilience hooks into OTP's application lifecycle via `prep_stop/1`. You don't need to call anything manually — just stop the application or send SIGTERM.

The shutdown is idempotent — calling `nova_resilience:prep_stop/0` explicitly is safe even though it also runs automatically.

## Configuration

```erlang
{nova_resilience, [
    {shutdown_delay, 5000},           %% ms to wait after marking not-ready
    {shutdown_drain_timeout, 15000}   %% Max ms to drain per priority group
]}.
```

## Drain behavior

During drain, nova_resilience monitors bulkhead occupancy for each dependency in the priority group. The drain phase:

1. Polls bulkhead status every 100ms
2. Exits early when all bulkheads report zero in-flight requests
3. Times out after `shutdown_drain_timeout` if requests don't complete

Dependencies without bulkheads have no occupancy tracking — the drain phase relies on the `shutdown_delay` to allow their in-flight work to complete.

## Shutdown priority

Dependencies are shut down in `shutdown_priority` order (ascending). Lower numbers shut down first.

Typical ordering:

| Priority | What | Why |
|----------|------|-----|
| 0 | HTTP service consumers | Stop accepting upstream work first |
| 1 | Kafka consumers | Stop consuming messages |
| 2 | Database pools | Drain queries last |

```erlang
{dependencies, [
    #{name => upstream_api, type => custom, shutdown_priority => 0},
    #{name => kafka, type => kafka, shutdown_priority => 1,
      client => my_brod_client, topic => ~"events"},
    #{name => primary_db, type => database, shutdown_priority => 2}
]}.
```

Dependencies with the same priority are shut down together as a group.

## Kubernetes integration

### Shutdown timing

Calculate your total shutdown time:

```
total = shutdown_delay
      + (shutdown_drain_timeout * number_of_priority_groups)
      + nova_http_drain_timeout
```

For defaults (5s delay, 15s drain, 3 priority groups, 15s Nova drain):

```
total = 5 + (15 * 3) + 15 = 65 seconds
```

Set `terminationGracePeriodSeconds` higher than this:

```yaml
spec:
  terminationGracePeriodSeconds: 75
```

### preStop hook

If your load balancer doesn't use readiness probes for routing (e.g. some cloud provider LBs), add a preStop hook:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
```

nova_resilience already handles the delay internally, so this is usually not needed with standard Kubernetes readiness-based routing.

## Adapter shutdown

Built-in adapters handle shutdown automatically:

| Adapter | Shutdown behavior |
|---------|-------------------|
| `pgo` | No-op (pgo pool handles its own shutdown) |
| `kura` | No-op (kura repo handles its own shutdown) |
| `brod` | Calls `brod:stop_client/1` |
| custom | Calls `YourAdapter:shutdown/1` |

Custom adapters should close connections, flush buffers, or release resources in `shutdown/1`.

## Telemetry events

| Event | When |
|-------|------|
| `[nova_resilience, gate, not_ready]` | System marked not-ready |
| `[nova_resilience, shutdown, start]` | Shutdown begins |
| `[nova_resilience, shutdown, stop]` | Shutdown complete (includes `duration` measurement) |

```erlang
telemetry:attach(
    ~"shutdown-monitor",
    [nova_resilience, shutdown, stop],
    fun(_Event, #{duration := Duration}, _Metadata, _Config) ->
        logger:notice(#{msg => ~"Shutdown complete", duration_ms => Duration})
    end,
    #{}
).
```
