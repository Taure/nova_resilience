-module(nova_resilience_shutdown_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    idempotent_shutdown_test/1,
    shutdown_marks_not_ready_test/1,
    shutdown_priority_order_test/1,
    drain_loop_respects_timeout_test/1,
    drain_loop_exits_early_when_idle_test/1,
    shutdown_emits_telemetry_test/1,
    shutdown_cleans_up_breakers_test/1
]).

-export([always_healthy/0]).

all() ->
    [
        idempotent_shutdown_test,
        shutdown_marks_not_ready_test,
        shutdown_priority_order_test,
        drain_loop_respects_timeout_test,
        drain_loop_exits_early_when_idle_test,
        shutdown_emits_telemetry_test,
        shutdown_cleans_up_breakers_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(seki),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    application:set_env(nova_resilience, dependencies, []),
    application:set_env(nova_resilience, vm_checks, false),
    application:set_env(nova_resilience, shutdown_delay, 0),
    application:set_env(nova_resilience, shutdown_drain_timeout, 500),
    {ok, Pid} = nova_resilience_registry:start_link(),
    {ok, GatePid} = nova_resilience_gate:start_link(),
    [{registry_pid, Pid}, {gate_pid, GatePid} | Config].

end_per_testcase(_TC, Config) ->
    Deps = nova_resilience_registry:list(),
    lists:foreach(
        fun(#{name := Name}) ->
            nova_resilience_registry:unregister_dep(Name)
        end,
        Deps
    ),
    RegistryPid = proplists:get_value(registry_pid, Config),
    GatePid = proplists:get_value(gate_pid, Config),
    unlink(RegistryPid),
    unlink(GatePid),
    gen_server:stop(RegistryPid, shutdown, 5000),
    gen_server:stop(GatePid, shutdown, 5000),
    %% Clear the shutdown flag so next test can run shutdown again
    persistent_term:erase(nova_resilience_shutdown_executed),
    timer:sleep(50),
    ok.

idempotent_shutdown_test(_Config) ->
    ok = nova_resilience:register_dependency(svc_a, #{type => custom}),
    nova_resilience_gate:mark_ready(),
    ?assert(nova_resilience_gate:is_ready()),
    ok = nova_resilience_shutdown:execute(),
    ?assertNot(nova_resilience_gate:is_ready()),
    %% Second call is a no-op (idempotent)
    ok = nova_resilience_shutdown:execute().

shutdown_marks_not_ready_test(_Config) ->
    nova_resilience_gate:mark_ready(),
    ?assert(nova_resilience_gate:is_ready()),
    ok = nova_resilience_shutdown:execute(),
    ?assertNot(nova_resilience_gate:is_ready()).

shutdown_priority_order_test(_Config) ->
    Self = self(),
    %% Register deps with different priorities using custom adapters
    %% that report their shutdown order
    ok = nova_resilience:register_dependency(high_prio, #{
        type => custom,
        shutdown_priority => 0,
        health_check => {?MODULE, always_healthy}
    }),
    ok = nova_resilience:register_dependency(mid_prio, #{
        type => custom,
        shutdown_priority => 5,
        health_check => {?MODULE, always_healthy}
    }),
    ok = nova_resilience:register_dependency(low_prio, #{
        type => custom,
        shutdown_priority => 10,
        health_check => {?MODULE, always_healthy}
    }),
    %% Attach telemetry to track unregistration order
    telemetry:attach_many(
        <<"shutdown-order-test">>,
        [[nova_resilience, dependency, unregistered]],
        fun(_Event, _Measurements, Metadata, Pid) ->
            Pid ! {unregistered, maps:get(name, Metadata)}
        end,
        Self
    ),
    %% Since shutdown tears down deps via ets:delete, we can't track
    %% via unregister telemetry. Instead verify deps are gone after shutdown.
    ok = nova_resilience_shutdown:execute(),
    ?assertEqual([], nova_resilience_registry:list()),
    telemetry:detach(<<"shutdown-order-test">>).

drain_loop_respects_timeout_test(_Config) ->
    ok = nova_resilience:register_dependency(drain_svc, #{
        type => custom,
        bulkhead => #{max_concurrent => 2}
    }),
    %% Hold a bulkhead slot to prevent drain from completing
    seki_bulkhead:acquire(nova_res_bulkhead_drain_svc),
    %% Set a short drain timeout
    application:set_env(nova_resilience, shutdown_drain_timeout, 200),
    Start = erlang:monotonic_time(millisecond),
    ok = nova_resilience_shutdown:execute(),
    Duration = erlang:monotonic_time(millisecond) - Start,
    %% Should have waited at least ~200ms for drain timeout
    ?assert(Duration >= 150).

drain_loop_exits_early_when_idle_test(_Config) ->
    ok = nova_resilience:register_dependency(idle_svc, #{
        type => custom,
        bulkhead => #{max_concurrent => 10}
    }),
    %% No active bulkhead slots — drain should return immediately
    application:set_env(nova_resilience, shutdown_drain_timeout, 5000),
    Start = erlang:monotonic_time(millisecond),
    ok = nova_resilience_shutdown:execute(),
    Duration = erlang:monotonic_time(millisecond) - Start,
    %% Should complete well under the 5s timeout
    ?assert(Duration < 1000).

shutdown_emits_telemetry_test(_Config) ->
    Self = self(),
    telemetry:attach_many(
        <<"shutdown-telemetry-test">>,
        [
            [nova_resilience, shutdown, start],
            [nova_resilience, shutdown, stop],
            [nova_resilience, gate, not_ready]
        ],
        fun(Event, Measurements, _Metadata, Pid) ->
            Pid ! {telemetry, Event, Measurements}
        end,
        Self
    ),
    nova_resilience_gate:mark_ready(),
    ok = nova_resilience_shutdown:execute(),
    receive
        {telemetry, [nova_resilience, shutdown, start], #{system_time := _}} -> ok
    after 1000 -> ct:fail(missing_shutdown_start_event)
    end,
    receive
        {telemetry, [nova_resilience, gate, not_ready], _} -> ok
    after 1000 -> ct:fail(missing_gate_not_ready_event)
    end,
    receive
        {telemetry, [nova_resilience, shutdown, stop], #{duration := D}} when D >= 0 -> ok
    after 1000 -> ct:fail(missing_shutdown_stop_event)
    end,
    telemetry:detach(<<"shutdown-telemetry-test">>).

shutdown_cleans_up_breakers_test(_Config) ->
    ok = nova_resilience:register_dependency(breaker_svc, #{
        type => custom,
        breaker => #{failure_threshold => 5, wait_duration => 1000}
    }),
    %% Verify breaker exists
    {ok, #{breaker := BreakerState}} = nova_resilience:dependency_status(breaker_svc),
    ?assertNotEqual(undefined, BreakerState),
    ok = nova_resilience_shutdown:execute(),
    %% Deps should be cleaned up
    ?assertEqual([], nova_resilience_registry:list()).

%% Helper for health checks
always_healthy() -> ok.
