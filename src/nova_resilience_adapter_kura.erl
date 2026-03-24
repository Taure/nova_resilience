-module(nova_resilience_adapter_kura).

-moduledoc """
Built-in adapter for PostgreSQL via kura.

Uses `kura_repo_worker:query/3` for health checks through the kura repo layer.

## Configuration

```erlang
#{name => primary_db,
  type => database,
  adapter => kura,
  repo => my_repo}          %% kura repo module
```
""".

-behaviour(nova_resilience_adapter).

-export([health_check/1, wrap_call/2, shutdown/1]).

-doc "Runs `SELECT 1` through the kura repo to verify connectivity.".
-spec health_check(map()) -> ok | {error, term()}.
health_check(#{repo := Repo}) ->
    try
        case kura_repo_worker:query(Repo, ~"SELECT 1", []) of
            {ok, _} -> ok;
            {error, Reason0} -> {error, Reason0}
        end
    catch
        Class:Reason1 ->
            {error, {Class, Reason1}}
    end.

-spec wrap_call(map(), fun(() -> term())) -> term().
wrap_call(_Config, Fun) ->
    Fun().

-spec shutdown(map()) -> ok.
shutdown(_Config) ->
    ok.
