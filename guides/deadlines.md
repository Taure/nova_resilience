# Deadline Propagation

Deadline propagation ensures that requests don't outlive their usefulness. If a client is willing to wait 5 seconds, there's no point continuing to process the request after those 5 seconds have elapsed.

## How it works

nova_resilience uses [Seki](https://github.com/Taure/seki) deadlines, which are per-process (stored in the process dictionary). When a deadline is set, every `nova_resilience:call/2,3` checks it before executing.

```
Request arrives with X-Request-Deadline header
  |
  +-- Deadline plugin reads header, sets seki deadline
  |
  +-- Handler calls nova_resilience:call(primary_db, Fun)
  |     |
  |     +-- Check deadline: exceeded? → {error, deadline_exceeded}
  |     +-- Not exceeded → execute Fun
  |
  +-- Handler calls nova_resilience:call(cache, Fun2)
  |     |
  |     +-- Check deadline: exceeded? → {error, deadline_exceeded}
  |     +-- Not exceeded → execute Fun2
  |
  +-- Response sent
  |
  +-- Deadline plugin clears deadline, emits telemetry if exceeded
```

## Setup

Add the deadline plugin to your Nova route groups:

```erlang
#{prefix => ~"/api",
  plugins => [
      {pre_request, nova_resilience_deadline_plugin, #{
          default_timeout => 30000    %% 30s default if no header
      }},
      {post_request, nova_resilience_deadline_plugin, #{}}
  ],
  routes => [
      {~"/users", {my_controller, users}, #{methods => [get]}},
      {~"/orders", {my_controller, orders}, #{methods => [get, post]}}
  ]}
```

## Plugin options

### Pre-request options

| Option | Default | Description |
|--------|---------|-------------|
| `default_timeout` | none | Default deadline in ms if no header present |
| `header` | `<<"x-request-deadline">>` | Header name to read deadline from |

### Post-request options

| Option | Default | Description |
|--------|---------|-------------|
| `propagate_response` | `false` | If true, sets `X-Deadline-Remaining` response header |

## Header format

The `X-Request-Deadline` header contains the absolute deadline as milliseconds since epoch:

```
X-Request-Deadline: 1711234567890
```

Upstream services (API gateways, other microservices) set this header to propagate the deadline through the call chain.

## Default timeouts

If no header is present and `default_timeout` is configured, the plugin sets a deadline relative to the current time:

```erlang
{pre_request, nova_resilience_deadline_plugin, #{
    default_timeout => 10000    %% 10 second timeout
}}
```

This ensures every request has a bounded lifetime even without upstream propagation.

## Per-dependency timeouts

Each dependency can also have a `default_timeout` that applies when `nova_resilience:call/2` is used:

```erlang
#{name => slow_api,
  type => custom,
  default_timeout => 5000}    %% 5s timeout for calls to this dep
```

If both a request-level deadline and a dependency-level timeout are set, the earlier one wins (seki tracks the tightest deadline).

## Override per call

```erlang
%% Use a specific timeout for this call
nova_resilience:call(primary_db, Fun, #{timeout => 2000}).
```

## Handling deadline exceeded

```erlang
case nova_resilience:call(slow_service, fun() ->
    external_api:fetch_report(params)
end) of
    {ok, Report} ->
        {json, Report};
    {error, deadline_exceeded} ->
        %% Request ran out of time — return 504
        {json, 504, #{}, #{error => ~"request timeout"}}
end.
```

## Response header

With `propagate_response => true`, the plugin adds the remaining time budget to the response:

```
X-Deadline-Remaining: 4523
```

This helps upstream services understand how much time was consumed.

## Telemetry

When a request deadline is exceeded, the plugin emits:

```erlang
[nova_resilience, request, deadline_exceeded]
%% Metadata: #{path => <<"/api/users">>, method => <<"GET">>}
```

Attach a handler to track which endpoints are timing out:

```erlang
telemetry:attach(
    ~"deadline-monitor",
    [nova_resilience, request, deadline_exceeded],
    fun(_Event, _Measurements, #{path := Path, method := Method}, _Config) ->
        logger:warning(#{msg => ~"Deadline exceeded", path => Path, method => Method})
    end,
    #{}
).
```
