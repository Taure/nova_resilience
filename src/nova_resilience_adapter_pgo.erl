-module(nova_resilience_adapter_pgo).

-moduledoc """
Built-in adapter for PostgreSQL via pgo.

Default adapter for `database` type dependencies. Uses `pgo:query/1,3`
for health checks.

## Configuration

```erlang
#{name => primary_db,
  type => database,
  %% adapter => pgo is implicit
  pool => default}          %% pgo pool name, optional
```
""".

-behaviour(nova_resilience_adapter).

-export([health_check/1, wrap_call/2, shutdown/1]).

-doc "Runs `SELECT 1` against the pool to verify connectivity.".
-spec health_check(map()) -> ok | {error, term()}.
health_check(#{pool := Pool}) ->
    do_check(#{pool => Pool});
health_check(_Config) ->
    do_check(#{}).

-spec wrap_call(map(), fun(() -> term())) -> term().
wrap_call(_Config, Fun) ->
    Fun().

-spec shutdown(map()) -> ok.
shutdown(_Config) ->
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

do_check(Opts) ->
    try
        case pgo:query(<<"SELECT 1">>, [], Opts) of
            #{command := select} -> ok;
            {error, Reason0} -> {error, Reason0}
        end
    catch
        Class:Reason1 ->
            {error, {Class, Reason1}}
    end.
