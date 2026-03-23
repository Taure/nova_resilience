# Adapters

Adapters provide built-in health checks and shutdown logic for known dependency types. You can use built-in adapters or write your own.

## Built-in adapters

### pgo (default for `database` type)

Health check runs `SELECT 1` against the pgo pool.

```erlang
#{name => primary_db,
  type => database,
  %% adapter => pgo is implicit
  pool => default}
```

Optional `pool` field — defaults to pgo's default pool if omitted.

### kura

Health check runs `SELECT 1` through the kura repo layer.

```erlang
#{name => primary_db,
  type => database,
  adapter => kura,
  repo => my_repo}
```

The `repo` field is required — it's the kura repo module that implements `kura_repo` behaviour.

### brod (default for `kafka` type)

Health check calls `brod:get_partitions_count/2` to verify broker connectivity. Shutdown calls `brod:stop_client/1`.

```erlang
#{name => events,
  type => kafka,
  client => my_brod_client,
  topic => ~"events"}
```

Both `client` and `topic` are required.

## Adapter resolution

nova_resilience resolves adapters in this order:

1. Explicit `adapter` field → use that module
2. `type => database` → `nova_resilience_adapter_pgo`
3. `type => kafka` → `nova_resilience_adapter_brod`
4. No type or `type => custom` → no adapter (no automatic health check)

## Custom adapters

Implement the `nova_resilience_adapter` behaviour:

```erlang
-module(my_redis_adapter).
-behaviour(nova_resilience_adapter).

-export([health_check/1, wrap_call/2, shutdown/1]).

health_check(#{pool := Pool}) ->
    case eredis:q(Pool, [~"PING"]) of
        {ok, ~"PONG"} -> ok;
        {error, Reason} -> {error, Reason}
    end.

wrap_call(_Config, Fun) ->
    %% Called around every nova_resilience:call/2,3
    %% Use for logging, tracing, connection checkout, etc.
    Fun().

shutdown(#{pool := Pool}) ->
    %% Called during graceful shutdown
    eredis:stop(Pool).
```

Then reference it in your config:

```erlang
#{name => cache,
  type => custom,
  adapter => my_redis_adapter,
  pool => redis_pool,
  critical => false,
  shutdown_priority => 0}
```

### Behaviour callbacks

| Callback | Return | Purpose |
|----------|--------|---------|
| `health_check(Config)` | `ok \| {error, Reason}` | Called periodically to check dependency health |
| `wrap_call(Config, Fun)` | `term()` | Wraps every call through the resilience stack |
| `shutdown(Config)` | `ok` | Called during graceful shutdown |

The `Config` parameter is the full dependency config map, so you can pass any fields you need.

### wrap_call examples

**Connection checkout:**

```erlang
wrap_call(#{pool := Pool}, Fun) ->
    case pool:checkout(Pool) of
        {ok, Conn} ->
            try Fun()
            after pool:checkin(Pool, Conn)
            end;
        {error, _} = Err ->
            Err
    end.
```

**Distributed tracing:**

```erlang
wrap_call(#{name := Name}, Fun) ->
    otel_tracer:with_span(Name, #{kind => client}, fun(_Ctx) ->
        Fun()
    end).
```

## Overriding health checks

Any dependency can override the adapter's health check with a custom `{Module, Function}` tuple:

```erlang
#{name => primary_db,
  type => database,
  adapter => pgo,
  health_check => {my_app_health, deep_db_check}}
```

The function must take zero arguments and return `ok | {error, Reason}`:

```erlang
-module(my_app_health).
-export([deep_db_check/0]).

deep_db_check() ->
    case pgo:query(~"SELECT count(*) FROM pg_stat_activity") of
        #{rows := [[Count]]} when Count < 100 -> ok;
        #{rows := [[Count]]} -> {error, {too_many_connections, Count}};
        {error, Reason} -> {error, Reason}
    end.
```

## Soft dependencies

All built-in adapters are soft dependencies — they're only loaded when used. Your application only needs to include the adapter libraries it actually uses (pgo, kura, brod).

## Runtime registration

Register dependencies at runtime for services discovered dynamically:

```erlang
nova_resilience:register_dependency(inventory_service, #{
    type => custom,
    adapter => my_http_adapter,
    url => "http://inventory:8080",
    critical => false,
    breaker => #{failure_threshold => 5, wait_duration => 30000}
}).

nova_resilience:call(inventory_service, fun() ->
    httpc:request("http://inventory:8080/api/stock")
end).

nova_resilience:unregister_dependency(inventory_service).
```
