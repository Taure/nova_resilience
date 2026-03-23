-module(nova_resilience_gate).

-moduledoc """
Startup readiness gate.

Tracks whether the system is ready to serve traffic. Uses `persistent_term`
for zero-cost per-request readiness checks. Gates readiness until all critical
dependencies pass their initial health checks.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([deps_provisioned/0, is_ready/0, mark_ready/0, mark_not_ready/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(READY_KEY, nova_resilience_ready).
-define(HEALTH_NAME, nova_resilience_health).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Called by the registry after all deps are provisioned. Starts health check polling.".
-spec deps_provisioned() -> ok.
deps_provisioned() ->
    gen_server:cast(?MODULE, deps_provisioned).

-doc "Check if the system is ready. Zero-cost persistent_term lookup.".
-spec is_ready() -> boolean().
is_ready() ->
    persistent_term:get(?READY_KEY, false).

-doc "Manually mark the system as ready.".
-spec mark_ready() -> ok.
mark_ready() ->
    gen_server:call(?MODULE, mark_ready).

-doc "Mark the system as not ready (used during shutdown).".
-spec mark_not_ready() -> ok.
mark_not_ready() ->
    case persistent_term:get(?READY_KEY, false) of
        true ->
            persistent_term:put(?READY_KEY, false),
            telemetry:execute(
                [nova_resilience, gate, not_ready],
                #{},
                #{reason => shutdown}
            );
        false ->
            ok
    end,
    ok.

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init([]) ->
    persistent_term:put(?READY_KEY, false),
    BootStart = erlang:monotonic_time(millisecond),
    {ok, #{boot_start => BootStart}}.

handle_call(mark_ready, _From, State) ->
    do_mark_ready(State),
    {reply, ok, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(deps_provisioned, State) ->
    case application:get_env(nova_resilience, gate_enabled, true) of
        false ->
            ?LOG_NOTICE(#{msg => ~"Gate disabled, marking ready immediately"}),
            do_mark_ready(State),
            {noreply, State};
        true ->
            CheckInterval = application:get_env(nova_resilience, gate_check_interval, 1000),
            erlang:send_after(0, self(), check_health),
            {noreply, State#{check_interval => CheckInterval}}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_health, State) ->
    #{check_interval := Interval} = State,
    GateTimeout = application:get_env(nova_resilience, gate_timeout, 30000),
    BootStart = maps:get(boot_start, State),
    Elapsed = erlang:monotonic_time(millisecond) - BootStart,

    case seki_health:readiness(?HEALTH_NAME) of
        ok ->
            do_mark_ready(State),
            {noreply, State};
        {error, _Checks} when Elapsed >= GateTimeout ->
            ?LOG_WARNING(#{
                msg => ~"Gate timeout reached, marking ready anyway",
                elapsed_ms => Elapsed
            }),
            do_mark_ready(State),
            {noreply, State};
        {error, NotReady} ->
            ?LOG_INFO(#{
                msg => ~"Waiting for critical dependencies",
                not_ready => NotReady,
                elapsed_ms => Elapsed
            }),
            erlang:send_after(Interval, self(), check_health),
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    persistent_term:erase(?READY_KEY),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

do_mark_ready(State) ->
    case persistent_term:get(?READY_KEY, false) of
        true ->
            ok;
        false ->
            persistent_term:put(?READY_KEY, true),
            BootTime = erlang:monotonic_time(millisecond) - maps:get(boot_start, State),
            telemetry:execute(
                [nova_resilience, gate, ready],
                #{boot_time => BootTime},
                #{}
            ),
            ?LOG_NOTICE(#{msg => ~"System ready", boot_time_ms => BootTime})
    end.
