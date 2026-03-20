# Getting Started

This guide walks through adding nova_resilience to an existing Nova application.

## Installation

Add `seki` and `nova_resilience` to your `rebar.config` deps:

```erlang
{deps, [
    nova,
    seki,
    nova_resilience
]}.
```

Add them to your `.app.src` applications list:

```erlang
{applications, [
    kernel, stdlib, nova, seki, nova_resilience
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
          shutdown_priority => 2}
    ]}
]}.
```

### Required fields

- `name` — Atom identifying the dependency
- `type` — `database`, `kafka`, or `custom`

### Optional fields

| Field | Default | Description |
|-------|---------|-------------|
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
    pgo:query(<<"SELECT * FROM users">>)
end) of
    {ok, Result} ->
        %% Result is whatever your fun returned
        handle_result(Result);
    {error, circuit_open} ->
        %% Dependency has too many failures, breaker tripped
        {json, 503, #{}, #{error => <<"service unavailable">>}};
    {error, bulkhead_full} ->
        %% Too many concurrent requests to this dependency
        {json, 503, #{}, #{error => <<"overloaded">>}};
    {error, deadline_exceeded} ->
        %% Request deadline expired
        {json, 504, #{}, #{error => <<"timeout">>}}
end.
```

Without a breaker or bulkhead configured, `call/2` still wraps the call with health tracking and telemetry.

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

### How it works

1. Pod starts, nova_resilience checks all critical dependencies
2. Startup probe polls `/ready` — returns 503 until deps are healthy
3. Once ready, Kubernetes routes traffic to the pod
4. On rolling deploy, SIGTERM is sent — nova_resilience marks not-ready, drains, shuts down deps
5. Kubernetes stops routing traffic (readiness probe fails)
6. Graceful termination completes

### Shutdown timing

Configure these to match your Kubernetes `terminationGracePeriodSeconds`:

```erlang
{nova_resilience, [
    {shutdown_delay, 5000},          %% Wait for LB to notice not-ready
    {shutdown_drain_timeout, 15000}  %% Max time to drain per dep group
]}.
```

Total shutdown time = `shutdown_delay` + (`shutdown_drain_timeout` * number of priority groups) + Nova's HTTP drain. Set your `terminationGracePeriodSeconds` accordingly.
