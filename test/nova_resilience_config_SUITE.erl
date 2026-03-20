-module(nova_resilience_config_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    valid_minimal_test/1,
    valid_full_test/1,
    not_a_map_test/1,
    missing_name_test/1,
    invalid_name_type_test/1,
    missing_kura_repo_test/1,
    missing_brod_fields_test/1,
    bad_breaker_opts_test/1,
    bad_breaker_threshold_test/1,
    bad_bulkhead_opts_test/1,
    bad_retry_opts_test/1,
    bad_shutdown_priority_test/1,
    bad_critical_test/1,
    custom_adapter_test/1,
    pgo_no_required_fields_test/1
]).

all() ->
    [
        valid_minimal_test,
        valid_full_test,
        not_a_map_test,
        missing_name_test,
        invalid_name_type_test,
        missing_kura_repo_test,
        missing_brod_fields_test,
        bad_breaker_opts_test,
        bad_breaker_threshold_test,
        bad_bulkhead_opts_test,
        bad_retry_opts_test,
        bad_shutdown_priority_test,
        bad_critical_test,
        custom_adapter_test,
        pgo_no_required_fields_test
    ].

valid_minimal_test(_Config) ->
    ?assertEqual(ok, nova_resilience_config:validate(#{name => my_dep, type => custom})).

valid_full_test(_Config) ->
    Config = #{
        name => primary_db,
        type => database,
        adapter => kura,
        repo => my_repo,
        critical => true,
        breaker => #{failure_threshold => 5, wait_duration => 30000},
        bulkhead => #{max_concurrent => 25},
        retry => #{max_attempts => 3, base_delay => 100, max_delay => 5000},
        shutdown_priority => 2,
        default_timeout => 10000
    },
    ?assertEqual(ok, nova_resilience_config:validate(Config)).

not_a_map_test(_Config) ->
    ?assertMatch(
        {error, [<<"dependency config must be a map">>]}, nova_resilience_config:validate(not_a_map)
    ).

missing_name_test(_Config) ->
    ?assertMatch(
        {error, [<<"missing required field 'name'">>]},
        nova_resilience_config:validate(#{type => custom})
    ).

invalid_name_type_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => "not_atom", type => custom}),
    ?assert(length(Errors) > 0),
    [Err | _] = Errors,
    ?assert(binary:match(Err, <<"'name' must be an atom">>) =/= nomatch).

missing_kura_repo_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => db, adapter => kura}),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"requires 'repo'">>) =/= nomatch end, Errors)).

missing_brod_fields_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => kafka, type => kafka}),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"requires 'client'">>) =/= nomatch end, Errors)),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"requires 'topic'">>) =/= nomatch end, Errors)).

bad_breaker_opts_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => x, breaker => not_a_map}),
    ?assert(
        lists:any(fun(E) -> binary:match(E, <<"'breaker' must be a map">>) =/= nomatch end, Errors)
    ).

bad_breaker_threshold_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{
        name => x, breaker => #{failure_threshold => -1}
    }),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"positive integer">>) =/= nomatch end, Errors)).

bad_bulkhead_opts_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => x, bulkhead => not_a_map}),
    ?assert(
        lists:any(fun(E) -> binary:match(E, <<"'bulkhead' must be a map">>) =/= nomatch end, Errors)
    ).

bad_retry_opts_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => x, retry => not_a_map}),
    ?assert(
        lists:any(fun(E) -> binary:match(E, <<"'retry' must be a map">>) =/= nomatch end, Errors)
    ).

bad_shutdown_priority_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => x, shutdown_priority => -1}),
    ?assert(
        lists:any(fun(E) -> binary:match(E, <<"non-negative integer">>) =/= nomatch end, Errors)
    ).

bad_critical_test(_Config) ->
    {error, Errors} = nova_resilience_config:validate(#{name => x, critical => "yes"}),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"must be a boolean">>) =/= nomatch end, Errors)).

custom_adapter_test(_Config) ->
    ?assertEqual(ok, nova_resilience_config:validate(#{name => x, adapter => my_custom_adapter})).

pgo_no_required_fields_test(_Config) ->
    ?assertEqual(ok, nova_resilience_config:validate(#{name => db, type => database})).
