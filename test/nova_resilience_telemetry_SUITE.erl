-module(nova_resilience_telemetry_SUITE).

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
    call_start_stop_telemetry_test/1,
    call_exception_telemetry_test/1,
    dependency_registered_telemetry_test/1,
    dependency_unregistered_telemetry_test/1,
    event_names_complete_test/1
]).

all() ->
    [
        call_start_stop_telemetry_test,
        call_exception_telemetry_test,
        dependency_registered_telemetry_test,
        dependency_unregistered_telemetry_test,
        event_names_complete_test
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
    timer:sleep(50),
    ok.

call_start_stop_telemetry_test(_Config) ->
    Self = self(),
    telemetry:attach_many(
        <<"call-telemetry-test">>,
        [
            [nova_resilience, call, start],
            [nova_resilience, call, stop]
        ],
        fun(Event, Measurements, Metadata, Pid) ->
            Pid ! {telemetry, Event, Measurements, Metadata}
        end,
        Self
    ),
    ok = nova_resilience:register_dependency(tel_svc, #{type => custom}),
    {ok, 42} = nova_resilience:call(tel_svc, fun() -> 42 end),
    receive
        {telemetry, [nova_resilience, call, start], #{system_time := _}, #{dep := tel_svc}} -> ok
    after 1000 -> ct:fail(missing_call_start)
    end,
    receive
        {telemetry, [nova_resilience, call, stop], #{duration := D}, #{
            dep := tel_svc, result := ok
        }} when D >= 0 ->
            ok
    after 1000 -> ct:fail(missing_call_stop)
    end,
    telemetry:detach(<<"call-telemetry-test">>).

call_exception_telemetry_test(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"call-exception-test">>,
        [nova_resilience, call, exception],
        fun(_Event, Measurements, Metadata, Pid) ->
            Pid ! {exception, Measurements, Metadata}
        end,
        Self
    ),
    ok = nova_resilience:register_dependency(err_svc, #{type => custom}),
    catch nova_resilience:call(err_svc, fun() -> error(boom) end),
    receive
        {exception, #{duration := D}, #{dep := err_svc, class := error, reason := boom}} when
            D >= 0
        ->
            ok
    after 1000 -> ct:fail(missing_call_exception)
    end,
    telemetry:detach(<<"call-exception-test">>).

dependency_registered_telemetry_test(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"dep-registered-test">>,
        [nova_resilience, dependency, registered],
        fun(_Event, Measurements, Metadata, Pid) ->
            Pid ! {registered, Measurements, Metadata}
        end,
        Self
    ),
    ok = nova_resilience:register_dependency(reg_svc, #{type => custom}),
    receive
        {registered, #{count := 1}, #{name := reg_svc, type := custom}} -> ok
    after 1000 -> ct:fail(missing_dep_registered)
    end,
    telemetry:detach(<<"dep-registered-test">>).

dependency_unregistered_telemetry_test(_Config) ->
    Self = self(),
    ok = nova_resilience:register_dependency(unreg_svc, #{type => custom}),
    telemetry:attach(
        <<"dep-unregistered-test">>,
        [nova_resilience, dependency, unregistered],
        fun(_Event, Measurements, Metadata, Pid) ->
            Pid ! {unregistered, Measurements, Metadata}
        end,
        Self
    ),
    ok = nova_resilience:unregister_dependency(unreg_svc),
    receive
        {unregistered, #{count := 1}, #{name := unreg_svc}} -> ok
    after 1000 -> ct:fail(missing_dep_unregistered)
    end,
    telemetry:detach(<<"dep-unregistered-test">>).

event_names_complete_test(_Config) ->
    Names = nova_resilience_telemetry:event_names(),
    Expected = [
        [nova_resilience, call, start],
        [nova_resilience, call, stop],
        [nova_resilience, call, exception],
        [nova_resilience, dependency, registered],
        [nova_resilience, dependency, unregistered],
        [nova_resilience, gate, ready],
        [nova_resilience, gate, not_ready],
        [nova_resilience, shutdown, start],
        [nova_resilience, shutdown, stop],
        [nova_resilience, request, deadline_exceeded],
        [nova_resilience, health, check]
    ],
    lists:foreach(
        fun(Event) ->
            ?assert(lists:member(Event, Names), {missing_event, Event})
        end,
        Expected
    ).
