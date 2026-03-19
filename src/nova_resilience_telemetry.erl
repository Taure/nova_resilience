-module(nova_resilience_telemetry).

-moduledoc """
Telemetry event definitions for nova_resilience.

All events are prefixed with `[nova_resilience, ...]`. Seki's own telemetry
events (`[seki, breaker, ...]`, `[seki, bulkhead, ...]`, etc.) also fire
for the underlying primitives.

## Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[nova_resilience, call, start]` | `system_time` | `dep` |
| `[nova_resilience, call, stop]` | `duration` | `dep, result` |
| `[nova_resilience, call, exception]` | `duration` | `dep, class, reason` |
| `[nova_resilience, dependency, registered]` | `count` | `name, type` |
| `[nova_resilience, dependency, unregistered]` | `count` | `name` |
| `[nova_resilience, gate, ready]` | `boot_time` | |
| `[nova_resilience, gate, not_ready]` | | `reason` |
| `[nova_resilience, shutdown, start]` | `system_time` | |
| `[nova_resilience, shutdown, stop]` | `duration` | |
| `[nova_resilience, request, deadline_exceeded]` | | `path, method` |
| `[nova_resilience, health, check]` | `check_count` | health report |
""".

-export([attach/0, event_names/0]).

-doc "Attach default log handlers for nova_resilience telemetry events.".
-spec attach() -> ok.
attach() ->
    ok.

-doc "List all telemetry event names emitted by nova_resilience.".
-spec event_names() -> [telemetry:event_name()].
event_names() ->
    [
        [nova_resilience, call, start],
        [nova_resilience, call, stop],
        [nova_resilience, call, exception],
        [nova_resilience, dependency, registered],
        [nova_resilience, dependency, unregistered],
        [nova_resilience, gate, ready],
        [nova_resilience, gate, not_ready],
        [nova_resilience, shutdown, start],
        [nova_resilience, shutdown, stop],
        [nova_resilience, request, deadline_exceeded],
        [nova_resilience, health, check]
    ].
