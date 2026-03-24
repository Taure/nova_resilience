# Circuit Breakers & Bulkheads

nova_resilience uses [Seki](https://github.com/Taure/seki) circuit breakers and bulkheads to protect your application from cascading failures.

## Circuit breakers

A circuit breaker monitors calls to a dependency and stops sending requests when failure rates exceed a threshold.

### States

- **Closed** — Normal operation. Failures are counted.
- **Open** — Too many failures. All calls immediately return `{error, circuit_open}`.
- **Half-open** — After `wait_duration`, a limited number of test calls are allowed through. If they succeed, the breaker closes. If they fail, it reopens.

### Configuration

```erlang
#{name => primary_db,
  type => database,
  breaker => #{
      failure_threshold => 5,       %% Failures before opening
      wait_duration => 30000,       %% ms to wait before half-open
      slow_call_duration => 5000,   %% Calls slower than this count as failures
      half_open_requests => 3,      %% Test calls allowed in half-open state
      window_type => count,         %% count or time
      window_size => 10             %% Window size (count or ms)
  }}
```

### Handling breaker states

```erlang
case nova_resilience:call(primary_db, fun() ->
    pgo:query(~"SELECT * FROM users")
end) of
    {ok, #{rows := Rows}} ->
        {json, #{users => Rows}};
    {error, circuit_open} ->
        %% Return cached data or a degraded response
        {json, 503, #{}, #{error => ~"database temporarily unavailable"}}
end.
```

### When to use circuit breakers

- Database connections that may become saturated
- External HTTP APIs that may go down
- Kafka brokers that may become unreachable
- Any network dependency that can fail

## Bulkheads

A bulkhead limits the number of concurrent requests to a dependency, preventing one slow dependency from consuming all available resources.

### Configuration

```erlang
#{name => primary_db,
  type => database,
  bulkhead => #{
      max_concurrent => 25    %% Maximum concurrent calls
  }}
```

### Handling bulkhead limits

```erlang
case nova_resilience:call(primary_db, fun() ->
    pgo:query(~"SELECT * FROM large_report")
end) of
    {ok, Result} ->
        {json, Result};
    {error, bulkhead_full} ->
        %% All slots occupied — shed load
        {json, 503, #{}, #{error => ~"too many concurrent requests"}}
end.
```

### Sizing bulkheads

Set `max_concurrent` based on what the dependency can handle:

- **Database pools** — Match your pgo pool size (e.g. 25 connections = 25 max_concurrent)
- **External APIs** — Match their rate limits or what you can reasonably send
- **Kafka** — Match your partition count or producer capacity

## Combining breaker and bulkhead

When both are configured, the execution order is:

```
1. Check deadline (not exceeded?)
2. Acquire bulkhead slot (capacity available?)
3. Execute through circuit breaker (breaker closed?)
   └── Retry wrapper (if configured)
       └── Adapter wrapper
           └── Your function
4. Release bulkhead slot
5. Emit telemetry
```

Example with both:

```erlang
#{name => primary_db,
  type => database,
  critical => true,
  breaker => #{failure_threshold => 5, wait_duration => 30000},
  bulkhead => #{max_concurrent => 25},
  retry => #{max_attempts => 3, base_delay => 100, max_delay => 2000}}
```

This means:
- Max 25 concurrent queries
- If 5 fail within the window, stop sending queries for 30s
- Each call retries up to 3 times with exponential backoff

## Retry

Retry wraps inside the circuit breaker — retried failures count toward the breaker threshold.

```erlang
#{name => flaky_api,
  type => custom,
  breaker => #{failure_threshold => 10, wait_duration => 60000},
  retry => #{
      max_attempts => 3,    %% Total attempts (1 initial + 2 retries)
      base_delay => 100,    %% ms before first retry
      max_delay => 5000     %% Maximum backoff cap
  }}
```

Override retry per-call:

```erlang
%% Disable retry for a specific call
nova_resilience:call(flaky_api, Fun, #{retry => false}).

%% Use different retry settings
nova_resilience:call(flaky_api, Fun, #{
    retry => #{max_attempts => 5, base_delay => 200, max_delay => 10000}
}).
```

## Dependencies without resilience primitives

You can register a dependency with no breaker, bulkhead, or retry:

```erlang
#{name => cache, type => custom, critical => false}
```

This still gives you:
- Health checking and `/health` reporting
- Startup gating (if `critical => true`)
- Telemetry on every call
- Ordered shutdown
- Deadline tracking

## Monitoring breaker state

Check the current state of any dependency:

```erlang
{ok, Status} = nova_resilience:dependency_status(primary_db).
%% #{name => primary_db,
%%   breaker => #{state => closed, failure_count => 0, ...},
%%   bulkhead => #{current => 3, max => 25, available => 22}}
```

The `/health` endpoint also includes breaker and bulkhead state for each dependency.
