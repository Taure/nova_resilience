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

Health check calls `brod:get_partitions_count/2` to verify broker connectivity.

```erlang
#{name => events,
  type => kafka,
  client => my_brod_client,
  topic => <<"events">>}
```

Both `client` and `topic` are required.

## Custom adapters

Implement the `nova_resilience_adapter` behaviour:

```erlang
-module(my_redis_adapter).
-behaviour(nova_resilience_adapter).

-export([health_check/1, wrap_call/2, shutdown/1]).

health_check(#{pool := Pool}) ->
    case eredis:q(Pool, [<<"PING">>]) of
        {ok, <<"PONG">>} -> ok;
        {error, Reason} -> {error, Reason}
    end.

wrap_call(_Config, Fun) ->
    Fun().

shutdown(_Config) ->
    ok.
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

## Overriding health checks

Any dependency can override the adapter's health check with a custom `{Module, Function}` tuple:

```erlang
#{name => primary_db,
  type => database,
  adapter => pgo,
  health_check => {my_app_health, deep_db_check}}
```

The function must return `ok | {error, Reason}`.

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

%% Then use it
nova_resilience:call(inventory_service, fun() ->
    httpc:request("http://inventory:8080/api/stock")
end).

%% Unregister when no longer needed
nova_resilience:unregister_dependency(inventory_service).
```
