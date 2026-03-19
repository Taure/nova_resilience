-module(nova_resilience_adapter_brod).

-moduledoc """
Built-in adapter for Kafka via brod.

Uses `brod:get_partitions_count/2` for health checks.

## Configuration

```erlang
#{name => kafka,
  type => kafka,
  client => my_brod_client,
  topic => <<"events">>}
```
""".

-behaviour(nova_resilience_adapter).

-export([health_check/1, wrap_call/2, shutdown/1]).

-doc "Checks broker connectivity by fetching partition count for the configured topic.".
-spec health_check(map()) -> ok | {error, term()}.
health_check(#{client := Client, topic := Topic}) ->
    try
        case brod:get_partitions_count(Client, Topic) of
            {ok, _Count} -> ok;
            {error, Reason0} -> {error, Reason0}
        end
    catch
        Class:Reason1 ->
            {error, {Class, Reason1}}
    end;
health_check(_Config) ->
    {error, missing_client_or_topic}.

-spec wrap_call(map(), fun(() -> term())) -> term().
wrap_call(_Config, Fun) ->
    Fun().

-doc "Stops the brod client if configured.".
-spec shutdown(map()) -> ok.
shutdown(#{client := Client}) ->
    try brod:stop_client(Client)
    catch _:_ -> ok
    end,
    ok;
shutdown(_Config) ->
    ok.
