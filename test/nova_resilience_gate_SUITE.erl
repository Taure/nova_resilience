-module(nova_resilience_gate_SUITE).

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
    starts_not_ready_test/1,
    mark_ready_test/1,
    mark_not_ready_test/1,
    mark_not_ready_idempotent_test/1,
    gate_timeout_forces_ready_test/1,
    deps_provisioned_triggers_health_check_test/1,
    ready_emits_telemetry_test/1,
    not_ready_emits_telemetry_test/1,
    gate_disabled_marks_ready_immediately_test/1
]).

-export([always_healthy/0, always_unhealthy/0]).

all() ->
    [
        starts_not_ready_test,
        mark_ready_test,
        mark_not_ready_test,
        mark_not_ready_idempotent_test,
        gate_timeout_forces_ready_test,
        deps_provisioned_triggers_health_check_test,
        ready_emits_telemetry_test,
        not_ready_emits_telemetry_test,
        gate_disabled_marks_ready_immediately_test
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
    application:set_env(nova_resilience, gate_check_interval, 50),
    application:set_env(nova_resilience, gate_timeout, 30000),
    {ok, RegPid} = nova_resilience_registry:start_link(),
    {ok, GatePid} = nova_resilience_gate:start_link(),
    [{registry_pid, RegPid}, {gate_pid, GatePid} | Config].

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
    persistent_term:erase(nova_resilience_shutdown_executed),
    timer:sleep(50),
    ok.

starts_not_ready_test(_Config) ->
    ?assertNot(nova_resilience_gate:is_ready()).

mark_ready_test(_Config) ->
    ?assertNot(nova_resilience_gate:is_ready()),
    ok = nova_resilience_gate:mark_ready(),
    ?assert(nova_resilience_gate:is_ready()).

mark_not_ready_test(_Config) ->
    ok = nova_resilience_gate:mark_ready(),
    ?assert(nova_resilience_gate:is_ready()),
    ok = nova_resilience_gate:mark_not_ready(),
    ?assertNot(nova_resilience_gate:is_ready()).

mark_not_ready_idempotent_test(_Config) ->
    %% Already not ready, calling mark_not_ready should be fine
    ?assertNot(nova_resilience_gate:is_ready()),
    ok = nova_resilience_gate:mark_not_ready(),
    ?assertNot(nova_resilience_gate:is_ready()).

gate_timeout_forces_ready_test(_Config) ->
    %% Register a dep with a health check that always fails
    ok = nova_resilience:register_dependency(failing_dep, #{
        type => custom,
        critical => true,
        health_check => {?MODULE, always_unhealthy}
    }),
    %% Set a very short gate timeout
    application:set_env(nova_resilience, gate_timeout, 100),
    %% Trigger health check polling
    nova_resilience_gate:deps_provisioned(),
    %% Wait for gate timeout to expire and force ready
    timer:sleep(500),
    ?assert(nova_resilience_gate:is_ready()).

deps_provisioned_triggers_health_check_test(_Config) ->
    %% Register a dep with a health check that succeeds
    ok = nova_resilience:register_dependency(healthy_dep, #{
        type => custom,
        critical => true,
        health_check => {?MODULE, always_healthy}
    }),
    %% Trigger health check polling
    nova_resilience_gate:deps_provisioned(),
    %% Should become ready once health check passes
    timer:sleep(200),
    ?assert(nova_resilience_gate:is_ready()).

ready_emits_telemetry_test(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"gate-ready-test">>,
        [nova_resilience, gate, ready],
        fun(_Event, Measurements, _Metadata, Pid) ->
            Pid ! {gate_ready, Measurements}
        end,
        Self
    ),
    ok = nova_resilience_gate:mark_ready(),
    receive
        {gate_ready, #{boot_time := BootTime}} when BootTime >= 0 -> ok
    after 1000 -> ct:fail(missing_gate_ready_event)
    end,
    telemetry:detach(<<"gate-ready-test">>).

not_ready_emits_telemetry_test(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"gate-not-ready-test">>,
        [nova_resilience, gate, not_ready],
        fun(_Event, _Measurements, Metadata, Pid) ->
            Pid ! {gate_not_ready, Metadata}
        end,
        Self
    ),
    ok = nova_resilience_gate:mark_ready(),
    ok = nova_resilience_gate:mark_not_ready(),
    receive
        {gate_not_ready, #{reason := shutdown}} -> ok
    after 1000 -> ct:fail(missing_gate_not_ready_event)
    end,
    telemetry:detach(<<"gate-not-ready-test">>).

gate_disabled_marks_ready_immediately_test(_Config) ->
    %% Register a dep with a health check that always fails
    ok = nova_resilience:register_dependency(failing_dep2, #{
        type => custom,
        critical => true,
        health_check => {?MODULE, always_unhealthy}
    }),
    %% Disable the gate
    application:set_env(nova_resilience, gate_enabled, false),
    ?assertNot(nova_resilience_gate:is_ready()),
    %% Trigger deps_provisioned — should mark ready immediately despite unhealthy dep
    nova_resilience_gate:deps_provisioned(),
    timer:sleep(100),
    ?assert(nova_resilience_gate:is_ready()),
    application:set_env(nova_resilience, gate_enabled, true).

%% Helpers
always_healthy() -> ok.
always_unhealthy() -> {error, still_failing}.
