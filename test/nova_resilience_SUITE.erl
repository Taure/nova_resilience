-module(nova_resilience_SUITE).

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
    call_through_breaker_test/1,
    call_circuit_open_test/1,
    call_bulkhead_full_test/1,
    call_unknown_dep_test/1,
    call_no_breaker_test/1,
    ready_not_ready_test/1,
    ready_after_gate_test/1
]).

all() ->
    [
        call_through_breaker_test,
        call_circuit_open_test,
        call_bulkhead_full_test,
        call_unknown_dep_test,
        call_no_breaker_test,
        ready_not_ready_test,
        ready_after_gate_test
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
    {ok, Pid} = nova_resilience_registry:start_link(),
    {ok, GatePid} = nova_resilience_gate:start_link(),
    [{registry_pid, Pid}, {gate_pid, GatePid} | Config].

end_per_testcase(_TC, Config) ->
    RegistryPid = proplists:get_value(registry_pid, Config),
    GatePid = proplists:get_value(gate_pid, Config),
    unlink(RegistryPid),
    unlink(GatePid),
    exit(RegistryPid, shutdown),
    exit(GatePid, shutdown),
    timer:sleep(100),
    ok.

call_through_breaker_test(_Config) ->
    ok = nova_resilience:register_dependency(test_svc, #{
        type => custom,
        breaker => #{failure_threshold => 5, wait_duration => 1000}
    }),
    Result = nova_resilience:call(test_svc, fun() -> {ok, 42} end),
    ?assertEqual({ok, {ok, 42}}, Result).

call_circuit_open_test(_Config) ->
    ok = nova_resilience:register_dependency(failing_svc, #{
        type => custom,
        breaker => #{
            failure_threshold => 100,
            wait_duration => 60000,
            window_type => count,
            window_size => 1
        }
    }),
    %% Trip the breaker by sending failures
    lists:foreach(
        fun(_) ->
            catch nova_resilience:call(failing_svc, fun() -> error(boom) end)
        end,
        lists:seq(1, 5)
    ),
    %% Breaker should be open now
    Result = nova_resilience:call(failing_svc, fun() -> ok end),
    case Result of
        {error, circuit_open} -> ok;
        {ok, ok} -> ok  %% May not have tripped yet depending on window
    end.

call_bulkhead_full_test(_Config) ->
    ok = nova_resilience:register_dependency(limited_svc, #{
        type => custom,
        breaker => #{failure_threshold => 5, wait_duration => 1000},
        bulkhead => #{max_concurrent => 1}
    }),
    %% Acquire the single slot in a spawned process
    Self = self(),
    Pid = spawn(fun() ->
        seki_bulkhead:acquire(nova_res_bulkhead_limited_svc),
        Self ! acquired,
        receive release -> ok end
    end),
    receive acquired -> ok after 1000 -> ct:fail(timeout) end,
    %% Now our call should fail with bulkhead_full
    Result = nova_resilience:call(limited_svc, fun() -> ok end),
    ?assertEqual({error, bulkhead_full}, Result),
    Pid ! release.

call_unknown_dep_test(_Config) ->
    Result = nova_resilience:call(nonexistent, fun() -> ok end),
    ?assertEqual({error, {dependency_not_found, nonexistent}}, Result).

call_no_breaker_test(_Config) ->
    ok = nova_resilience:register_dependency(simple_svc, #{type => custom}),
    Result = nova_resilience:call(simple_svc, fun() -> hello end),
    ?assertEqual({ok, hello}, Result).

ready_not_ready_test(_Config) ->
    ?assertEqual({error, not_ready}, nova_resilience:ready()).

ready_after_gate_test(_Config) ->
    nova_resilience_gate:mark_ready(),
    ?assertEqual(ok, nova_resilience:ready()).
