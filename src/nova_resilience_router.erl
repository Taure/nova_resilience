-module(nova_resilience_router).

-moduledoc """
Nova router for nova_resilience health endpoints.

Registers `/health`, `/ready`, and `/live` routes. Add `nova_resilience` to
your app's `nova_apps` config to include these routes:

```erlang
{my_app, [{nova_apps, [nova_resilience]}]}.
```

Configure the prefix via `{nova_resilience, [{health_prefix, <<"/api">>}]}`.
""".

-behaviour(nova_router).

-export([routes/1]).

routes(_Env) ->
    Prefix = application:get_env(nova_resilience, health_prefix, <<"">>),
    [#{
        prefix => Prefix,
        security => false,
        plugins => [],
        routes => [
            {<<"/health">>, fun nova_resilience_health_controller:health/1, #{methods => [get]}},
            {<<"/ready">>, fun nova_resilience_health_controller:ready/1, #{methods => [get]}},
            {<<"/live">>, fun nova_resilience_health_controller:live/1, #{methods => [get]}}
        ]
    }].
