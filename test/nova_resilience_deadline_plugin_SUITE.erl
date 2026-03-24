-module(nova_resilience_deadline_plugin_SUITE).

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
    pre_request_no_header_no_default_test/1,
    pre_request_sets_default_timeout_test/1,
    pre_request_reads_header_test/1,
    pre_request_ignores_invalid_header_test/1,
    post_request_clears_deadline_test/1,
    post_request_emits_deadline_exceeded_test/1,
    custom_header_name_test/1
]).

all() ->
    [
        pre_request_no_header_no_default_test,
        pre_request_sets_default_timeout_test,
        pre_request_reads_header_test,
        pre_request_ignores_invalid_header_test,
        post_request_clears_deadline_test,
        post_request_emits_deadline_exceeded_test,
        custom_header_name_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(seki),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    meck:new(cowboy_req, [passthrough, no_link]),
    Config.

end_per_testcase(_TC, _Config) ->
    seki_deadline:clear(),
    meck:unload(cowboy_req),
    ok.

pre_request_no_header_no_default_test(_Config) ->
    Req = make_req(#{}),
    meck:expect(cowboy_req, header, fun(<<"x-request-deadline">>, _R) -> undefined end),
    {ok, Req, state} = nova_resilience_deadline_plugin:pre_request(Req, #{}, #{}, state),
    %% No deadline should be set
    ?assertEqual(ok, seki_deadline:check()).

pre_request_sets_default_timeout_test(_Config) ->
    Req = make_req(#{}),
    meck:expect(cowboy_req, header, fun(<<"x-request-deadline">>, _R) -> undefined end),
    Opts = #{default_timeout => 5000},
    {ok, Req, state} = nova_resilience_deadline_plugin:pre_request(Req, #{}, Opts, state),
    %% Deadline should be set — check should still be ok (not exceeded yet)
    ?assertEqual(ok, seki_deadline:check()).

pre_request_reads_header_test(_Config) ->
    Req = make_req(#{}),
    %% Set a deadline far in the future
    FutureMs = integer_to_binary(erlang:system_time(millisecond) + 60000),
    meck:expect(cowboy_req, header, fun(<<"x-request-deadline">>, _R) -> FutureMs end),
    {ok, Req, state} = nova_resilience_deadline_plugin:pre_request(Req, #{}, #{}, state),
    ?assertEqual(ok, seki_deadline:check()).

pre_request_ignores_invalid_header_test(_Config) ->
    Req = make_req(#{}),
    meck:expect(cowboy_req, header, fun(<<"x-request-deadline">>, _R) -> <<"not-a-number">> end),
    %% Should not crash, just ignore
    {ok, Req, state} = nova_resilience_deadline_plugin:pre_request(Req, #{}, #{}, state).

post_request_clears_deadline_test(_Config) ->
    seki_deadline:set(60000),
    ?assertEqual(ok, seki_deadline:check()),
    Req = make_req(#{}),
    meck:expect(cowboy_req, path, fun(_R) -> <<"/test">> end),
    meck:expect(cowboy_req, method, fun(_R) -> <<"GET">> end),
    {ok, _Req1, state} = nova_resilience_deadline_plugin:post_request(Req, #{}, #{}, state),
    %% Deadline should be cleared — check returns ok (no deadline = not exceeded)
    ?assertEqual(ok, seki_deadline:check()).

post_request_emits_deadline_exceeded_test(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"deadline-exceeded-test">>,
        [nova_resilience, request, deadline_exceeded],
        fun(_Event, _Measurements, Metadata, Pid) ->
            Pid ! {deadline_exceeded, Metadata}
        end,
        Self
    ),
    %% Set an already-expired deadline
    seki_deadline:set(1),
    timer:sleep(10),
    Req = make_req(#{}),
    meck:expect(cowboy_req, path, fun(_R) -> <<"/api/users">> end),
    meck:expect(cowboy_req, method, fun(_R) -> <<"POST">> end),
    {ok, _Req1, state} = nova_resilience_deadline_plugin:post_request(Req, #{}, #{}, state),
    receive
        {deadline_exceeded, #{path := <<"/api/users">>, method := <<"POST">>}} -> ok
    after 1000 -> ct:fail(missing_deadline_exceeded_event)
    end,
    telemetry:detach(<<"deadline-exceeded-test">>).

custom_header_name_test(_Config) ->
    Req = make_req(#{}),
    FutureMs = integer_to_binary(erlang:system_time(millisecond) + 60000),
    meck:expect(cowboy_req, header, fun(<<"x-custom-deadline">>, _R) -> FutureMs end),
    Opts = #{header => <<"x-custom-deadline">>},
    {ok, Req, state} = nova_resilience_deadline_plugin:pre_request(Req, #{}, Opts, state),
    ?assertEqual(ok, seki_deadline:check()).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

make_req(Headers) ->
    #{headers => Headers, path => <<"/test">>, method => <<"GET">>}.
