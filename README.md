# nova_resilience

Production-grade resilience patterns for [Nova](https://github.com/novaframework/nova) web applications.

Bridges Nova and [Seki](https://github.com/Taure/seki) to provide dependency health checking, Kubernetes-ready probes, circuit breakers, bulkheads, deadline propagation, and ordered graceful shutdown — all via declarative configuration.

## Features

- **Health endpoints** — `/health`, `/ready`, `/live` for Kubernetes probes
- **Startup gating** — traffic held until critical dependencies are healthy
- **Circuit breakers** — stop calling failing dependencies, allow recovery
- **Bulkheads** — limit concurrent requests per dependency
- **Retry** — configurable retry with exponential backoff and jitter
- **Deadline propagation** — per-request timeouts via headers or defaults
- **Graceful shutdown** — ordered teardown with drain, priority groups, and LB coordination
- **Telemetry** — events for all resilience operations (calls, breakers, shutdown, health)
- **Pluggable adapters** — built-in support for pgo, kura, brod, or custom

## Quick start

Add to your deps:

```erlang
{deps, [
    nova,
    seki,
    nova_resilience
]}.
```

Add to your `.app.src` applications:

```erlang
{applications, [kernel, stdlib, nova, seki, nova_resilience]}.
```

Register health routes in your Nova config:

```erlang
{my_app, [
    {nova_apps, [nova_resilience]}
]}.
```

Configure dependencies in `sys.config`:

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
          shutdown_priority => 2}
    ]}
]}.
```

That's it. Your app now has `/health`, `/ready`, and `/live` endpoints, automatic startup gating, circuit breakers, bulkheads, and ordered shutdown.

## How it works

### Startup

1. App starts, nova_resilience provisions seki primitives for each dependency
2. Health checks run — `/ready` returns **503** until all critical deps are healthy
3. Kubernetes readiness probe holds traffic until ready
4. Once healthy, `/ready` returns **200** and traffic flows

### Running

Wrap calls to external dependencies through the resilience stack:

```erlang
case nova_resilience:call(primary_db, fun() ->
    pgo:query(~"SELECT * FROM users WHERE id = $1", [Id])
end) of
    {ok, #{rows := Rows}} ->
        {json, #{users => Rows}};
    {error, circuit_open} ->
        {json, 503, #{}, #{error => ~"db unavailable"}};
    {error, bulkhead_full} ->
        {json, 503, #{}, #{error => ~"overloaded"}};
    {error, deadline_exceeded} ->
        {json, 504, #{}, #{error => ~"timeout"}}
end.
```

### Shutdown

On SIGTERM (or application stop):

1. `/ready` immediately returns **503** (load balancer stops sending traffic)
2. Waits `shutdown_delay` for LB health checks to propagate
3. Drains in-flight requests (monitors bulkhead occupancy)
4. Tears down dependencies in `shutdown_priority` order
5. Nova drains HTTP connections and stops

No manual `prep_stop` calls needed — shutdown is fully automatic.

## Health endpoints

| Endpoint | Purpose | Response |
|----------|---------|----------|
| `GET /health` | Full diagnostic report | `{"status":"healthy","dependencies":{...},"vm":{...}}` |
| `GET /ready` | Kubernetes readiness probe | 200 when ready, 503 when not |
| `GET /live` | Kubernetes liveness probe | 200 if process is responsive |

The `/health` endpoint returns per-dependency status with circuit breaker state, bulkhead occupancy, and VM metrics (memory, process count, run queue, uptime, node).

## Configuration

### Application environment

```erlang
{nova_resilience, [
    {dependencies, [...]},            %% List of dependency configs
    {health_check_interval, 10000},   %% ms between health checks
    {vm_checks, true},                %% Include BEAM VM info in health report
    {gate_enabled, true},             %% false to skip startup gating (dev/test)
    {gate_timeout, 30000},            %% Max ms to wait for deps on startup
    {gate_check_interval, 1000},      %% ms between gate readiness checks
    {health_severity, info},          %% critical: /health returns 503 when unhealthy
    {shutdown_delay, 5000},           %% ms to wait after marking not-ready
    {shutdown_drain_timeout, 15000},  %% Max ms to drain per priority group
    {drain_poll_interval, 100},       %% ms between drain occupancy polls
    {health_prefix, ~""}              %% Prefix for health routes (e.g. ~"/internal")
]}.
```

Unknown config keys are logged as warnings on startup to catch typos.

### Dependency config

```erlang
#{
    name => atom(),                    %% Required — unique identifier
    type => database | kafka | custom, %% Optional — infers adapter
    adapter => pgo | kura | brod | module(), %% Optional — inferred from type
    critical => boolean(),             %% Default: false — gates /ready
    shutdown_priority => non_neg_integer(), %% Default: 10 — lower = first
    default_timeout => pos_integer(),  %% Default deadline in ms
    health_check => {module(), function()}, %% Override adapter health check

    %% Circuit breaker
    breaker => #{
        failure_threshold => pos_integer(),
        wait_duration => pos_integer(),
        slow_call_duration => pos_integer(),
        half_open_requests => pos_integer()
    },

    %% Concurrency limiter
    bulkhead => #{
        max_concurrent => pos_integer()
    },

    %% Retry with backoff
    retry => #{
        max_attempts => pos_integer(),
        base_delay => non_neg_integer(),
        max_delay => non_neg_integer()
    }
}
```

## Built-in adapters

| Type | Adapter | Health check | Shutdown |
|------|---------|-------------|----------|
| `database` | `pgo` (default) | `SELECT 1` via pgo pool | no-op |
| `database` | `kura` | `SELECT 1` via kura repo | no-op |
| `kafka` | `brod` | `brod:get_partitions_count/2` | `brod:stop_client/1` |
| any | custom module | `nova_resilience_adapter` behaviour | custom |

## Guides

- [Getting Started](guides/getting-started.md) — Installation and basic setup
- [Circuit Breakers & Bulkheads](guides/resilience-patterns.md) — Protecting dependencies
- [Deadline Propagation](guides/deadlines.md) — Per-request timeout budgets
- [Adapters](guides/adapters.md) — Built-in and custom adapters
- [Graceful Shutdown](guides/shutdown.md) — Ordered teardown and Kubernetes integration
- [Telemetry](guides/telemetry.md) — Observability and monitoring

## License

Apache-2.0
