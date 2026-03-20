# Graceful Shutdown

nova_resilience provides ordered graceful shutdown that coordinates with Nova's HTTP connection draining.

## How it works

When the BEAM receives SIGTERM (or the application stops), the shutdown sequence is:

```
1. nova_resilience prep_stop
   |
   +-- Mark not-ready (/ready returns 503)
   |
   +-- Wait shutdown_delay (default 5s)
   |     Load balancer detects not-ready, stops sending traffic
   |
   +-- For each priority group (ascending):
   |     +-- Close bulkheads (reject new work)
   |     +-- Wait for in-flight to drain
   |     +-- Delete circuit breakers
   |     +-- Run adapter shutdown
   |     +-- Unregister health checks
   |
   +-- Done

2. Nova prep_stop
   |
   +-- Suspend listener (stop accepting connections)
   +-- Drain active connections (default 15s)
   +-- Stop listener
```

## Shutdown is automatic

nova_resilience hooks into OTP's application lifecycle via `prep_stop/1`. You don't need to call anything manually — just stop the application or send SIGTERM.

## Configuration

```erlang
{nova_resilience, [
    {shutdown_delay, 5000},          %% ms to wait after marking not-ready
    {shutdown_drain_timeout, 15000}  %% ms to drain per priority group
]}.
```

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
    #{name => kafka, type => kafka, shutdown_priority => 1},
    #{name => primary_db, type => database, shutdown_priority => 2}
]}.
```

Dependencies with the same priority are shut down together as a group.

## Idempotency

The shutdown sequence is idempotent — calling it multiple times is safe. This means you can still call `nova_resilience:prep_stop/0` explicitly if you need the shutdown to happen at a specific point in your app's lifecycle, even though it will also run automatically.

## Kubernetes integration

Set `terminationGracePeriodSeconds` in your pod spec to be larger than your total shutdown time:

```
total = shutdown_delay + (shutdown_drain_timeout * priority_groups) + nova_drain_timeout
```

For the defaults (5s delay, 15s drain, 1 priority group, 15s Nova drain):

```
total = 5 + 15 + 15 = 35 seconds
```

Set `terminationGracePeriodSeconds: 45` to give some headroom.

## Telemetry events

| Event | When |
|-------|------|
| `[nova_resilience, shutdown, start]` | Shutdown begins |
| `[nova_resilience, shutdown, stop]` | Shutdown complete (includes `duration` measurement) |
| `[nova_resilience, gate, not_ready]` | System marked not-ready |
