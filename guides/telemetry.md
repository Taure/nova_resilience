# Telemetry

nova_resilience emits [telemetry](https://github.com/beam-telemetry/telemetry) events for all resilience operations. Use these for monitoring, alerting, and dashboards.

## Events

### Call events

Emitted on every `nova_resilience:call/2,3`:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, call, start]` | `system_time` (ms) | `dep` |
| `[nova_resilience, call, stop]` | `duration` (ms) | `dep`, `result` |
| `[nova_resilience, call, exception]` | `duration` (ms) | `dep`, `class`, `reason` |

`result` is `ok` for successful calls or `{error, Reason}` for failures.

### Dependency lifecycle

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, dependency, registered]` | `count` (always 1) | `name`, `type` |
| `[nova_resilience, dependency, unregistered]` | `count` (always 1) | `name` |

### Gate events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, gate, ready]` | `boot_time` (ms) | — |
| `[nova_resilience, gate, not_ready]` | — | `reason` |

`boot_time` is the time from application start to the system becoming ready.

### Shutdown events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, shutdown, start]` | `system_time` (ms) | — |
| `[nova_resilience, shutdown, stop]` | `duration` (ms) | — |

### Request events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, request, deadline_exceeded]` | — | `path`, `method` |

### Health check events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, health, check]` | `check_count` | full health report |

Emitted on every `GET /health` request.

## Seki events

Seki emits its own telemetry events for the underlying primitives. These fire alongside nova_resilience events:

- `[seki, breaker, state_change]` — Circuit breaker state transitions
- `[seki, bulkhead, acquired]` / `[seki, bulkhead, rejected]` — Bulkhead slot events
- `[seki, retry, attempt]` — Retry attempts

## Attaching handlers

### Basic logging

```erlang
telemetry:attach_many(
    ~"resilience-logger",
    [
        [nova_resilience, call, stop],
        [nova_resilience, call, exception]
    ],
    fun
        ([nova_resilience, call, stop], #{duration := D}, #{dep := Dep, result := Result}, _) ->
            logger:info(#{msg => ~"resilience_call", dep => Dep, duration_ms => D, result => Result});
        ([nova_resilience, call, exception], #{duration := D}, #{dep := Dep, reason := R}, _) ->
            logger:error(#{msg => ~"resilience_call_exception", dep => Dep, duration_ms => D, reason => R})
    end,
    #{}
).
```

### Metrics (OpenTelemetry)

```erlang
%% In your app's start/2
opentelemetry_telemetry:attach_many(~"resilience-otel", [
    [nova_resilience, call, start],
    [nova_resilience, call, stop],
    [nova_resilience, call, exception]
]).
```

### Alerting on breaker state

```erlang
telemetry:attach(
    ~"breaker-alert",
    [seki, breaker, state_change],
    fun(_Event, _Measurements, #{name := Name, from := From, to := To}, _Config) ->
        case To of
            open ->
                logger:alert(#{
                    msg => ~"Circuit breaker opened",
                    dep => Name,
                    from => From
                });
            _ ->
                logger:notice(#{
                    msg => ~"Circuit breaker state change",
                    dep => Name,
                    from => From,
                    to => To
                })
        end
    end,
    #{}
).
```

### Startup monitoring

```erlang
telemetry:attach(
    ~"boot-monitor",
    [nova_resilience, gate, ready],
    fun(_Event, #{boot_time := BootTime}, _Metadata, _Config) ->
        logger:notice(#{msg => ~"System ready", boot_time_ms => BootTime})
    end,
    #{}
).
```

## Event names list

Get all event names programmatically:

```erlang
Events = nova_resilience_telemetry:event_names().
```

This is useful for registering handlers or validating your telemetry setup.
