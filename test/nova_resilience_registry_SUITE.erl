-module(nova_resilience_registry_SUITE).

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
    register_and_lookup_test/1,
    unregister_test/1,
    list_deps_test/1,
    duplicate_register_test/1,
    adapter_resolution_pgo_default_test/1,
    adapter_resolution_kura_test/1,
    adapter_resolution_custom_test/1
]).

all() ->
    [
        register_and_lookup_test,
        unregister_test,
        list_deps_test,
        duplicate_register_test,
        adapter_resolution_pgo_default_test,
        adapter_resolution_kura_test,
        adapter_resolution_custom_test
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

register_and_lookup_test(_Config) ->
    ok = nova_resilience_registry:register_dep(test_db, #{
        type => custom,
        breaker => #{failure_threshold => 5, wait_duration => 1000},
        critical => false
    }),
    {ok, Dep} = nova_resilience_registry:lookup(test_db),
    ?assertEqual(test_db, element(2, Dep)),
    ?assertEqual(custom, element(3, Dep)).

unregister_test(_Config) ->
    ok = nova_resilience_registry:register_dep(test_svc, #{
        type => custom,
        breaker => #{failure_threshold => 5, wait_duration => 1000}
    }),
    {ok, _} = nova_resilience_registry:lookup(test_svc),
    ok = nova_resilience_registry:unregister_dep(test_svc),
    ?assertEqual({error, not_found}, nova_resilience_registry:lookup(test_svc)).

list_deps_test(_Config) ->
    ok = nova_resilience_registry:register_dep(dep_a, #{type => custom}),
    ok = nova_resilience_registry:register_dep(dep_b, #{type => custom}),
    Deps = nova_resilience_registry:list(),
    Names = [maps:get(name, D) || D <- Deps],
    ?assert(lists:member(dep_a, Names)),
    ?assert(lists:member(dep_b, Names)).

duplicate_register_test(_Config) ->
    ok = nova_resilience_registry:register_dep(dup_dep, #{type => custom}),
    ?assertEqual({error, already_registered},
                 nova_resilience_registry:register_dep(dup_dep, #{type => custom})).

adapter_resolution_pgo_default_test(_Config) ->
    ok = nova_resilience_registry:register_dep(db_pgo, #{
        type => database,
        breaker => #{failure_threshold => 5, wait_duration => 1000}
    }),
    {ok, Dep} = nova_resilience_registry:lookup(db_pgo),
    ?assertEqual(nova_resilience_adapter_pgo, element(4, Dep)).

adapter_resolution_kura_test(_Config) ->
    ok = nova_resilience_registry:register_dep(db_kura, #{
        type => database,
        adapter => kura,
        repo => my_repo,
        breaker => #{failure_threshold => 5, wait_duration => 1000}
    }),
    {ok, Dep} = nova_resilience_registry:lookup(db_kura),
    ?assertEqual(nova_resilience_adapter_kura, element(4, Dep)).

adapter_resolution_custom_test(_Config) ->
    ok = nova_resilience_registry:register_dep(custom_dep, #{
        type => custom,
        adapter => my_custom_adapter,
        breaker => #{failure_threshold => 5, wait_duration => 1000}
    }),
    {ok, Dep} = nova_resilience_registry:lookup(custom_dep),
    ?assertEqual(my_custom_adapter, element(4, Dep)).
