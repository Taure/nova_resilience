-module(nova_resilience).

-moduledoc """
Main API for nova_resilience.

Execute calls through the resilience stack (circuit breaker, bulkhead, retry,
deadline), register/unregister dependencies at runtime, and query health status.

## Example

```erlang
case nova_resilience:call(primary_db, fun() -> my_repo:all(users) end) of
    {ok, {ok, Users}} -> {json, #{users => Users}};
    {error, circuit_open} -> {status, 503};
    {error, bulkhead_full} -> {status, 503};
    {error, deadline_exceeded} -> {status, 504}
end.
```
""".

-include_lib("kernel/include/logger.hrl").

%% Dependency registration
-export([
    register_dependency/2,
    unregister_dependency/1,
    list_dependencies/0,
    dependency_status/1
]).

-deprecated([{prep_stop, 0, "Shutdown is now automatic. Remove prep_stop/0 calls."}]).

%% Execute through resilience stack
-export([
    call/2,
    call/3
]).

%% Health queries
-export([
    health/0,
    ready/0,
    live/0
]).

%% Shutdown
-export([
    prep_stop/0
]).

-type dep_name() :: atom().
-type call_opts() :: #{
    timeout => pos_integer(),
    retry => seki_retry:retry_opts() | false,
    breaker_opts => map()
}.

-export_type([dep_name/0, call_opts/0]).

%%----------------------------------------------------------------------
%% Dependency registration
%%----------------------------------------------------------------------

-doc "Register a dependency at runtime.".
-spec register_dependency(atom(), map()) -> ok | {error, term()}.
register_dependency(Name, Config) ->
    nova_resilience_registry:register_dep(Name, Config).

-doc "Unregister a dependency and tear down its seki primitives.".
-spec unregister_dependency(atom()) -> ok.
unregister_dependency(Name) ->
    nova_resilience_registry:unregister_dep(Name).

-doc "List all registered dependencies.".
-spec list_dependencies() -> [map()].
list_dependencies() ->
    nova_resilience_registry:list().

-doc "Get status of a single dependency.".
-spec dependency_status(atom()) -> {ok, map()} | {error, not_found}.
dependency_status(Name) ->
    nova_resilience_registry:status(Name).

%%----------------------------------------------------------------------
%% Execute through resilience stack
%%----------------------------------------------------------------------

-doc "Execute a function through the resilience stack for the named dependency.".
-spec call(dep_name(), fun(() -> term())) -> {ok, term()} | {error, term()}.
call(Dep, Fun) ->
    call(Dep, Fun, #{}).

-doc """
Execute a function through the resilience stack with options.

The execution flow is:
1. Set deadline (from opts or dependency default)
2. Check deadline not exceeded
3. Acquire bulkhead slot (if configured)
4. Execute through circuit breaker
   - Retry wrapping inside breaker (if configured)
5. Release bulkhead
6. Emit telemetry
""".
-spec call(dep_name(), fun(() -> term()), call_opts()) -> {ok, term()} | {error, term()}.
call(Dep, Fun, CallOpts) ->
    case nova_resilience_registry:lookup(Dep) of
        {error, not_found} ->
            {error, {dependency_not_found, Dep}};
        {ok, DepRec} ->
            Start = erlang:monotonic_time(millisecond),
            telemetry:execute(
                [nova_resilience, call, start],
                #{system_time => erlang:system_time(millisecond)},
                #{dep => Dep}
            ),
            try do_call(DepRec, Fun, CallOpts) of
                Result ->
                    Duration0 = erlang:monotonic_time(millisecond) - Start,
                    telemetry:execute(
                        [nova_resilience, call, stop],
                        #{duration => Duration0},
                        #{dep => Dep, result => result_type(Result)}
                    ),
                    Result
            catch
                Class:Reason:Stack ->
                    Duration1 = erlang:monotonic_time(millisecond) - Start,
                    telemetry:execute(
                        [nova_resilience, call, exception],
                        #{duration => Duration1},
                        #{dep => Dep, class => Class, reason => Reason}
                    ),
                    erlang:raise(Class, Reason, Stack)
            end
    end.

%%----------------------------------------------------------------------
%% Health queries
%%----------------------------------------------------------------------

-doc "Get full health report with all dependencies.".
-spec health() -> map().
health() ->
    nova_resilience_health_controller:build_health_report().

-doc "Check if the system is ready to serve traffic.".
-spec ready() -> ok | {error, not_ready}.
ready() ->
    case nova_resilience_gate:is_ready() of
        true -> ok;
        false -> {error, not_ready}
    end.

-doc "Check if the system is alive (process is responsive).".
-spec live() -> ok.
live() ->
    ok.

%%----------------------------------------------------------------------
%% Shutdown
%%----------------------------------------------------------------------

-doc """
Ordered graceful shutdown.

Deprecated: shutdown is now automatic via `nova_resilience_app:prep_stop/1`.
You no longer need to call this from your app. Safe to call — it's idempotent.
""".
-spec prep_stop() -> ok.
prep_stop() ->
    nova_resilience_shutdown:execute().

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% Access record fields via element/2 since we can't include the record
%% definition from another module. Field positions match #dep{} in registry.
%% name=2, type=3, adapter=4, adapter_config=5, breaker_name=6,
%% bulkhead_name=7, retry_opts=8, default_timeout=9

do_call(DepRec, Fun, CallOpts) ->
    DefaultTimeout = element(9, DepRec),
    Timeout = maps:get(timeout, CallOpts, DefaultTimeout),
    maybe_set_deadline(Timeout),

    case seki_deadline:check() of
        {error, deadline_exceeded} = Err ->
            Err;
        ok ->
            BulkheadName = element(7, DepRec),
            with_bulkhead(BulkheadName, DepRec, Fun, CallOpts)
    end.

with_bulkhead(undefined, DepRec, Fun, CallOpts) ->
    with_breaker(DepRec, Fun, CallOpts);
with_bulkhead(BulkheadName, DepRec, Fun, CallOpts) ->
    case seki_bulkhead:acquire(BulkheadName) of
        ok ->
            try
                with_breaker(DepRec, Fun, CallOpts)
            after
                seki_bulkhead:release(BulkheadName)
            end;
        {error, bulkhead_full} = Err ->
            Err
    end.

with_breaker(DepRec, Fun, CallOpts) ->
    BreakerName = element(6, DepRec),
    WrappedFun = wrap_with_retry(DepRec, Fun, CallOpts),
    Adapter = element(4, DepRec),
    AdapterConfig = element(5, DepRec),
    AdaptedFun = wrap_with_adapter(Adapter, AdapterConfig, WrappedFun),
    case BreakerName of
        undefined ->
            {ok, AdaptedFun()};
        _ ->
            BreakerOpts = maps:get(breaker_opts, CallOpts, #{}),
            seki:call(BreakerName, AdaptedFun, BreakerOpts)
    end.

wrap_with_retry(DepRec, Fun, CallOpts) ->
    DepRetry = element(8, DepRec),
    RetryOpts =
        case maps:get(retry, CallOpts, DepRetry) of
            false -> undefined;
            undefined -> undefined;
            R -> R
        end,
    case RetryOpts of
        undefined ->
            Fun;
        _ ->
            DepName = element(2, DepRec),
            fun() ->
                case seki_retry:run(DepName, Fun, RetryOpts) of
                    {ok, Result} -> Result;
                    {error, _} = Err -> Err
                end
            end
    end.

wrap_with_adapter(undefined, _Config, Fun) ->
    Fun;
wrap_with_adapter(Adapter, Config, Fun) ->
    fun() -> Adapter:wrap_call(Config, Fun) end.

maybe_set_deadline(undefined) -> ok;
maybe_set_deadline(Timeout) -> seki_deadline:set(Timeout).

result_type({ok, _}) -> ok;
result_type({error, Reason}) -> {error, Reason}.
