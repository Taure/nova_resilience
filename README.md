# nova_resilience

Production-grade resilience patterns for [Nova](https://github.com/novaframework/nova) web applications.

Bridges Nova and [Seki](https://github.com/Taure/seki) to provide dependency health checking, Kubernetes-ready probes, circuit breakers, bulkheads, and ordered graceful shutdown — all via declarative configuration.

## Quick start

Add to your deps:

```erlang
{deps, [
    nova,
    seki,
    nova_resilience
]}.
```

Add to your app's `applications`:

```erlang
{applications, [kernel, stdlib, nova, seki, nova_resilience]}.
```

Register health routes in your Nova config:

```erlang
{my_app, [
    {nova_apps, [nova_resilience]}
]}.
```

Configure dependencies:

```erlang
{nova_resilience, [
    {dependencies, [
        #{name => primary_db,
          type => database,
          adapter => pgo,
          pool => default,
          critical => true,
          shutdown_priority => 2}
    ]}
]}.
```

That's it. Your app now has `/health`, `/ready`, and `/live` endpoints, automatic startup gating, and ordered shutdown.

## What it does

### Startup

1. App starts, nova_resilience provisions health checks for each dependency
2. `/ready` returns **503** until all critical dependencies are healthy
3. Kubernetes readiness probe detects this and holds traffic
4. Once all critical deps respond, `/ready` returns **200** and traffic flows

### Running

Execute calls through the resilience stack:

```erlang
case nova_resilience:call(primary_db, fun() ->
    pgo:query(<<"SELECT * FROM users WHERE id = $1">>, [Id])
end) of
    {ok, #{rows := Rows}} -> {json, #{users => Rows}};
    {error, circuit_open} -> {json, 503, #{}, #{error => <<"db unavailable">>}};
    {error, bulkhead_full} -> {json, 503, #{}, #{error => <<"overloaded">>}}
end.
```

### Shutdown

On SIGTERM (or application stop):

1. `/ready` immediately returns **503** (load balancer stops sending traffic)
2. Waits `shutdown_delay` for in-flight LB health checks to propagate
3. Tears down dependencies in `shutdown_priority` order
4. Nova drains HTTP connections and stops

No manual `prep_stop` calls needed — shutdown is fully automatic.

## Health endpoints

| Endpoint | Purpose | Response |
|----------|---------|----------|
| `GET /health` | Full health report | `{"status":"healthy","dependencies":{...},"vm":{...}}` |
| `GET /ready` | Kubernetes readiness probe | 200 when ready, 503 when not |
| `GET /live` | Kubernetes liveness probe | 200 if process is responsive |

## Configuration

```erlang
{nova_resilience, [
    {dependencies, [...]},          %% List of dependency configs
    {health_check_interval, 10000}, %% ms between health checks
    {vm_checks, true},              %% Include BEAM VM in health report
    {gate_timeout, 30000},          %% Max ms to wait for deps on startup
    {shutdown_delay, 5000},         %% ms to wait after marking not-ready
    {shutdown_drain_timeout, 15000},%% Max ms to drain per priority group
    {health_prefix, <<"">>}         %% Prefix for health routes
]}.
```

## Built-in adapters

| Type | Adapter | Auto health check |
|------|---------|-------------------|
| `database` | `pgo` (default) | `SELECT 1` via pgo |
| `database` | `kura` | `SELECT 1` via kura repo |
| `kafka` | `brod` | `brod:get_partitions_count/2` |
| any | custom module | Implement `nova_resilience_adapter` behaviour |

## License

Apache-2.0
