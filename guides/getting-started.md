# Getting Started

This guide walks through adding nova_resilience to an existing Nova application.

## Installation

Add `nova_resilience` to your `rebar.config` deps:

```erlang
{deps, [
    nova,
    nova_resilience
]}.
```

Add it to your `.app.src` applications list:

```erlang
{applications, [
    kernel, stdlib, nova, nova_resilience
]}.
```

## Register health routes

Add `nova_resilience` to your app's `nova_apps` so the health endpoints get registered:

```erlang
%% In sys.config
{my_app, [
    {nova_apps, [nova_resilience]}
]}.
```

This gives you `/health`, `/ready`, and `/live` endpoints automatically.

To prefix the health routes (e.g. behind `/internal`):

```erlang
{nova_resilience, [
    {health_prefix, ~"/internal"}
]}.
```

This registers `/internal/health`, `/internal/ready`, and `/internal/live`.

## Configure dependencies

Add a `nova_resilience` section to your `sys.config`:

```erlang
{nova_resilience, [
    {dependencies, [
        #{name => primary_db,
          type => database,
          adapter => pgo,
          pool => default,
          critical => true,
          breaker => #{failure_threshold => 5, wait_duration => 30000},
          bulkhead => #{max_concurrent => 25},
          shutdown_priority => 2},

        #{name => events,
          type => kafka,
          client => my_brod_client,
          topic => ~"events",
          critical => true,
          breaker => #{failure_threshold => 3, wait_duration => 10000},
          shutdown_priority => 1}
    ]}
]}.
```

### Required fields

- `name` — Atom identifying the dependency (must be unique)

### Optional fields

| Field | Default | Description |
|-------|---------|-------------|
| `type` | `custom` | `database`, `kafka`, or `custom` |
| `adapter` | auto from type | `pgo`, `kura`, `brod`, or custom module |
| `critical` | `false` | If true, `/ready` returns 503 when this dep is unhealthy |
| `shutdown_priority` | `10` | Lower numbers shut down first |
| `breaker` | none | Circuit breaker options (map) |
| `bulkhead` | none | Concurrency limiter options (map) |
| `retry` | none | Retry options (map) |
| `default_timeout` | none | Default deadline in ms |
| `health_check` | auto from adapter | `{Module, Function}` tuple for custom health checks |

## Using the resilience stack

Wrap calls to external dependencies:

```erlang
case nova_resilience:call(primary_db, fun() ->
    pgo:query(~"SELECT * FROM users")
end) of
    {ok, Result} ->
        handle_result(Result);
    {error, circuit_open} ->
        {json, 503, #{}, #{error => ~"service unavailable"}};
    {error, bulkhead_full} ->
        {json, 503, #{}, #{error => ~"overloaded"}};
    {error, deadline_exceeded} ->
        {json, 504, #{}, #{error => ~"timeout"}}
end.
```

Without a breaker or bulkhead configured, `call/2` still wraps the call with telemetry and deadline tracking.

### Call options

Override per-call settings with `call/3`:

```erlang
nova_resilience:call(primary_db, Fun, #{
    timeout => 5000,           %% Override deadline for this call
    retry => #{                %% Override retry for this call
        max_attempts => 3,
        base_delay => 100,
        max_delay => 2000
    }
}).
```

Pass `retry => false` to disable retry for a single call.

## Health endpoints

Once running, verify your setup:

```bash
# Full health report
curl http://localhost:8080/health | jq .

# Readiness probe
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/ready

# Liveness probe
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/live
```

Example `/health` response:

```json
{
  "status": "healthy",
  "dependencies": {
    "primary_db": {
      "status": "healthy",
      "details": {},
      "name": "primary_db",
      "breaker": {"state": "closed", "failure_count": 0},
      "bulkhead": {"current": 3, "max": 25, "available": 22}
    }
  },
  "vm": {
    "memory_mb": 64,
    "process_count": 312,
    "run_queue": 0,
    "uptime_seconds": 3600,
    "node": "my_app@hostname"
  }
}
```

## Kubernetes deployment

### Pod spec

```yaml
containers:
  - name: my-app
    livenessProbe:
      httpGet:
        path: /live
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      initialDelaySeconds: 2
      periodSeconds: 5
    startupProbe:
      httpGet:
        path: /ready
        port: 8080
      failureThreshold: 30
      periodSeconds: 2
```

### Lifecycle

1. Pod starts, nova_resilience checks all critical dependencies
2. Startup probe polls `/ready` — returns 503 until deps are healthy
3. Once ready, Kubernetes routes traffic to the pod
4. On rolling deploy, SIGTERM fires — nova_resilience marks not-ready, drains, shuts down deps
5. Kubernetes stops routing traffic (readiness probe fails)
6. Graceful termination completes

### Shutdown timing

Total shutdown time = `shutdown_delay` + (`shutdown_drain_timeout` x priority groups) + Nova HTTP drain.

For defaults (5s delay, 15s drain, 1 priority group, 15s Nova drain):

```
total = 5 + 15 + 15 = 35 seconds
```

Set `terminationGracePeriodSeconds: 45` to give headroom.

## Development and testing

In development you may not have all dependencies running. Disable the startup gate to skip health check blocking:

```erlang
%% dev.config
{nova_resilience, [
    {gate_enabled, false},
    {dependencies, [...]}
]}.
```

With `gate_enabled => false`, `/ready` returns 200 immediately on startup regardless of dependency health.

To have `/health` return 503 when critical dependencies are unhealthy (useful for monitoring systems that scrape `/health`):

```erlang
{nova_resilience, [
    {health_severity, critical}
]}.
```

With the default `info` severity, `/health` always returns 200 with the full report. With `critical`, it returns 503 when the system is unhealthy.

## Runtime registration

Register dependencies dynamically (e.g. discovered via service mesh):

```erlang
ok = nova_resilience:register_dependency(inventory_api, #{
    type => custom,
    adapter => my_http_adapter,
    url => "http://inventory:8080",
    breaker => #{failure_threshold => 5, wait_duration => 30000}
}).

%% Use it
nova_resilience:call(inventory_api, fun() ->
    httpc:request("http://inventory:8080/api/stock")
end).

%% Unregister when no longer needed
nova_resilience:unregister_dependency(inventory_api).
```

## Next steps

- [Circuit Breakers & Bulkheads](resilience-patterns.md) — Protect against cascading failures
- [Deadline Propagation](deadlines.md) — Manage request timeout budgets
- [Adapters](adapters.md) — Write custom adapters for your dependencies
- [Graceful Shutdown](shutdown.md) — Ordered teardown and Kubernetes integration
- [Telemetry](telemetry.md) — Monitoring and observability
