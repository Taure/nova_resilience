-module(nova_resilience_registry).

-moduledoc """
Central registry for external dependencies.

Owns an ETS table mapping dependency names to their configs and seki primitive
names. On init, reads configuration from application env and provisions seki
breakers, bulkheads, and health checks for each dependency.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([register_dep/2, unregister_dep/1, lookup/1, list/0, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, nova_resilience_deps).
-define(HEALTH_NAME, nova_resilience_health).

-record(dep, {
    name :: atom(),
    type :: atom(),
    adapter :: module() | undefined,
    adapter_config :: map(),
    breaker_name :: atom() | undefined,
    bulkhead_name :: atom() | undefined,
    retry_opts :: map() | undefined,
    default_timeout :: pos_integer() | undefined,
    shutdown_priority :: non_neg_integer(),
    critical :: boolean()
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Register a dependency at runtime.".
-spec register_dep(atom(), map()) -> ok | {error, term()}.
register_dep(Name, Config) ->
    gen_server:call(?MODULE, {register, Name, Config}).

-doc "Unregister a dependency and tear down its seki primitives.".
-spec unregister_dep(atom()) -> ok.
unregister_dep(Name) ->
    gen_server:call(?MODULE, {unregister, Name}).

-doc "Look up a dependency record. Fast ETS read, no gen_server call.".
-spec lookup(atom()) -> {ok, #dep{}} | {error, not_found}.
lookup(Name) ->
    case ets:lookup(?TABLE, Name) of
        [Dep] -> {ok, Dep};
        [] -> {error, not_found}
    end.

-doc "List all registered dependencies.".
-spec list() -> [map()].
list() ->
    [dep_to_map(D) || D <- ets:tab2list(?TABLE)].

-doc "Get status of a single dependency (breaker state, bulkhead info).".
-spec status(atom()) -> {ok, map()} | {error, not_found}.
status(Name) ->
    case lookup(Name) of
        {ok, Dep} -> {ok, build_status(Dep)};
        Error -> Error
    end.

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init([]) ->
    Table =
        case ets:whereis(?TABLE) of
            undefined ->
                ets:new(?TABLE, [
                    named_table,
                    {keypos, #dep.name},
                    set,
                    public,
                    {read_concurrency, true}
                ]);
            Tid ->
                ets:delete_all_objects(Tid),
                Tid
        end,
    Deps = application:get_env(nova_resilience, dependencies, []),
    VmChecks = application:get_env(nova_resilience, vm_checks, true),
    Interval = application:get_env(nova_resilience, health_check_interval, 10000),
    %% Clean up any existing health process from previous run
    catch seki:delete_health(?HEALTH_NAME),
    {ok, _} = seki:new_health(?HEALTH_NAME, #{
        vm_checks => VmChecks,
        check_interval => Interval
    }),
    case validate_and_provision_all(Deps) of
        ok ->
            nova_resilience_gate:deps_provisioned(),
            {ok, #{table => Table}};
        {error, Reasons} ->
            ?LOG_ERROR(#{msg => <<"Invalid dependency config">>, errors => Reasons}),
            {stop, {invalid_config, Reasons}}
    end.

handle_call({register, Name, Config}, _From, State) ->
    FullConfig = Config#{name => Name},
    case nova_resilience_config:validate(FullConfig) of
        ok ->
            case ets:lookup(?TABLE, Name) of
                [_] ->
                    {reply, {error, already_registered}, State};
                [] ->
                    ok = provision_dep(FullConfig),
                    {reply, ok, State}
            end;
        {error, Errors} ->
            {reply, {error, {invalid_config, Errors}}, State}
    end;
handle_call({unregister, Name}, _From, State) ->
    teardown_dep(Name),
    {reply, ok, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    persistent_term:erase(nova_resilience_shutdown_executed),
    _ = seki:delete_health(?HEALTH_NAME),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

validate_and_provision_all(Deps) ->
    Errors = lists:foldl(
        fun(Config, Acc) ->
            case nova_resilience_config:validate(Config) of
                ok -> Acc;
                {error, Errs} -> [{maps:get(name, Config, unknown), Errs} | Acc]
            end
        end,
        [],
        Deps
    ),
    case Errors of
        [] ->
            lists:foreach(fun(Config) -> provision_dep(Config) end, Deps),
            ok;
        _ ->
            {error, Errors}
    end.

provision_dep(Config) ->
    Name = maps:get(name, Config),
    Type = maps:get(type, Config, custom),
    Critical = maps:get(critical, Config, false),
    ShutdownPriority = maps:get(shutdown_priority, Config, 10),
    DefaultTimeout = maps:get(default_timeout, Config, undefined),
    RetryOpts = maps:get(retry, Config, undefined),

    Adapter = resolve_adapter(Config),
    AdapterConfig = Config,

    BreakerName = provision_breaker(Name, Config),
    BulkheadName = provision_bulkhead(Name, Config),
    register_health_check(Name, Adapter, AdapterConfig, Config, Critical),

    Dep = #dep{
        name = Name,
        type = Type,
        adapter = Adapter,
        adapter_config = AdapterConfig,
        breaker_name = BreakerName,
        bulkhead_name = BulkheadName,
        retry_opts = RetryOpts,
        default_timeout = DefaultTimeout,
        shutdown_priority = ShutdownPriority,
        critical = Critical
    },
    ets:insert(?TABLE, Dep),

    telemetry:execute(
        [nova_resilience, dependency, registered],
        #{count => 1},
        #{name => Name, type => Type}
    ),

    ?LOG_NOTICE(#{msg => <<"Dependency registered">>, name => Name, type => Type}),
    ok.

provision_breaker(Name, Config) ->
    case maps:get(breaker, Config, undefined) of
        undefined ->
            undefined;
        BreakerOpts ->
            BreakerName = breaker_name(Name),
            case seki:new_breaker(BreakerName, BreakerOpts) of
                {ok, _Pid} -> BreakerName;
                {error, {already_started, _}} -> BreakerName
            end
    end.

provision_bulkhead(Name, Config) ->
    case maps:get(bulkhead, Config, undefined) of
        undefined ->
            undefined;
        BulkheadOpts ->
            BulkheadName = bulkhead_name(Name),
            case seki:new_bulkhead(BulkheadName, BulkheadOpts) of
                {ok, _Pid} -> BulkheadName;
                {error, {already_started, _}} -> BulkheadName
            end
    end.

register_health_check(Name, Adapter, AdapterConfig, Config, Critical) ->
    HealthFun = build_health_fun(Adapter, AdapterConfig, Config),
    seki_health:register_check(?HEALTH_NAME, Name, HealthFun, #{critical => Critical}).

build_health_fun(_Adapter, _AdapterConfig, #{health_check := {M, F}}) ->
    fun() ->
        case M:F() of
            ok -> {healthy, #{}};
            {error, Reason} -> {unhealthy, #{reason => Reason}}
        end
    end;
build_health_fun(undefined, _AdapterConfig, _Config) ->
    fun() -> {healthy, #{}} end;
build_health_fun(Adapter, AdapterConfig, _Config) ->
    fun() ->
        case Adapter:health_check(AdapterConfig) of
            ok -> {healthy, #{}};
            {error, Reason} -> {unhealthy, #{reason => Reason}}
        end
    end.

teardown_dep(Name) ->
    case ets:lookup(?TABLE, Name) of
        [Dep] ->
            teardown_breaker(Dep#dep.breaker_name),
            teardown_bulkhead(Dep#dep.bulkhead_name),
            teardown_adapter(Dep#dep.adapter, Dep#dep.adapter_config),
            seki_health:unregister_check(?HEALTH_NAME, Name),
            ets:delete(?TABLE, Name),
            telemetry:execute(
                [nova_resilience, dependency, unregistered],
                #{count => 1},
                #{name => Name}
            ),
            ok;
        [] ->
            ok
    end.

teardown_breaker(undefined) ->
    ok;
teardown_breaker(Name) ->
    _ = seki:delete_breaker(Name),
    ok.

teardown_bulkhead(undefined) ->
    ok;
teardown_bulkhead(Name) ->
    _ = seki:delete_bulkhead(Name),
    ok.

teardown_adapter(undefined, _Config) ->
    ok;
teardown_adapter(Adapter, Config) ->
    try
        Adapter:shutdown(Config)
    catch
        _:_ -> ok
    end.

resolve_adapter(#{adapter := Adapter}) when is_atom(Adapter), Adapter =/= undefined ->
    adapter_module(Adapter);
resolve_adapter(#{type := database}) ->
    nova_resilience_adapter_pgo;
resolve_adapter(#{type := kafka}) ->
    nova_resilience_adapter_brod;
resolve_adapter(_) ->
    undefined.

adapter_module(pgo) -> nova_resilience_adapter_pgo;
adapter_module(kura) -> nova_resilience_adapter_kura;
adapter_module(brod) -> nova_resilience_adapter_brod;
adapter_module(Module) -> Module.

breaker_name(DepName) ->
    list_to_atom("nova_res_breaker_" ++ atom_to_list(DepName)).

bulkhead_name(DepName) ->
    list_to_atom("nova_res_bulkhead_" ++ atom_to_list(DepName)).

dep_to_map(#dep{
    name = Name,
    type = Type,
    critical = Critical,
    shutdown_priority = Prio
}) ->
    #{name => Name, type => Type, critical => Critical, shutdown_priority => Prio}.

build_status(#dep{name = Name, breaker_name = BreakerName, bulkhead_name = BulkheadName}) ->
    BreakerState =
        case BreakerName of
            undefined -> undefined;
            _ -> seki:state(BreakerName)
        end,
    BulkheadStatus =
        case BulkheadName of
            undefined -> undefined;
            _ -> seki_bulkhead:status(BulkheadName)
        end,
    #{name => Name, breaker => BreakerState, bulkhead => BulkheadStatus}.
