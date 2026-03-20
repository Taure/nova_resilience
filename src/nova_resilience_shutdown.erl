-module(nova_resilience_shutdown).

-moduledoc """
Ordered shutdown coordinator.

Tears down dependencies in priority order after marking the system as not-ready
and waiting for load balancers to drain traffic.
""".

-include_lib("kernel/include/logger.hrl").

-export([execute/0]).

-define(TABLE, nova_resilience_deps).

-doc """
Execute ordered shutdown.

1. Mark system not-ready (health probes return 503)
2. Wait `shutdown_delay` for LB to stop sending traffic
3. Tear down dependencies in `shutdown_priority` order (ascending)
4. Clean up seki primitives
""".
-define(SHUTDOWN_KEY, nova_resilience_shutdown_executed).

-spec execute() -> ok.
execute() ->
    case persistent_term:get(?SHUTDOWN_KEY, false) of
        true ->
            ok;
        false ->
            persistent_term:put(?SHUTDOWN_KEY, true),
            do_execute()
    end.

do_execute() ->
    Start = erlang:monotonic_time(millisecond),
    telemetry:execute(
        [nova_resilience, shutdown, start], #{system_time => erlang:system_time(millisecond)}, #{}
    ),

    ?LOG_NOTICE(#{msg => <<"Resilience shutdown started">>}),

    nova_resilience_gate:mark_not_ready(),

    Delay = application:get_env(nova_resilience, shutdown_delay, 5000),
    ?LOG_NOTICE(#{msg => <<"Waiting for traffic drain">>, delay_ms => Delay}),
    timer:sleep(Delay),

    DrainTimeout = application:get_env(nova_resilience, shutdown_drain_timeout, 15000),
    shutdown_by_priority(DrainTimeout),

    Duration = erlang:monotonic_time(millisecond) - Start,
    telemetry:execute([nova_resilience, shutdown, stop], #{duration => Duration}, #{}),
    ?LOG_NOTICE(#{msg => <<"Resilience shutdown complete">>, duration_ms => Duration}),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

shutdown_by_priority(DrainTimeout) ->
    Deps = ets:tab2list(?TABLE),
    %% Group by shutdown_priority
    Grouped = lists:foldl(
        fun(Dep, Acc) ->
            Prio = element(10, Dep),
            maps:update_with(Prio, fun(L) -> [Dep | L] end, [Dep], Acc)
        end,
        #{},
        Deps
    ),
    Priorities = lists:sort(maps:keys(Grouped)),
    lists:foreach(
        fun(Prio) ->
            Group = maps:get(Prio, Grouped),
            Names = [element(2, D) || D <- Group],
            ?LOG_NOTICE(#{
                msg => <<"Shutting down priority group">>, priority => Prio, deps => Names
            }),
            shutdown_group(Group, DrainTimeout)
        end,
        Priorities
    ).

shutdown_group(Deps, DrainTimeout) ->
    %% Close bulkheads first to reject new work
    lists:foreach(
        fun(Dep) ->
            case element(7, Dep) of
                undefined ->
                    ok;
                BulkheadName ->
                    ?LOG_INFO(#{msg => <<"Closing bulkhead">>, name => element(2, Dep)}),
                    _ = seki:delete_bulkhead(BulkheadName)
            end
        end,
        Deps
    ),

    %% Wait for in-flight to drain
    drain_inflight(DrainTimeout),

    %% Delete breakers and run adapter shutdown
    lists:foreach(
        fun(Dep) ->
            Name = element(2, Dep),
            _ =
                case element(6, Dep) of
                    undefined ->
                        ok;
                    BreakerName ->
                        ?LOG_INFO(#{msg => <<"Deleting breaker">>, name => Name}),
                        seki:delete_breaker(BreakerName)
                end,
            Adapter = element(4, Dep),
            AdapterConfig = element(5, Dep),
            case Adapter of
                undefined ->
                    ok;
                _ ->
                    try
                        Adapter:shutdown(AdapterConfig)
                    catch
                        C:R ->
                            ?LOG_WARNING(#{
                                msg => <<"Adapter shutdown error">>,
                                name => Name,
                                class => C,
                                reason => R
                            })
                    end
            end,
            seki_health:unregister_check(nova_resilience_health, Name),
            ets:delete(?TABLE, Name)
        end,
        Deps
    ).

drain_inflight(Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    drain_loop(Deadline).

drain_loop(Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            ?LOG_WARNING(#{msg => <<"Drain timeout reached">>}),
            ok;
        false ->
            timer:sleep(500),
            ok
    end.
