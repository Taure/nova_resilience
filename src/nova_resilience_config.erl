-module(nova_resilience_config).

-moduledoc """
Validates dependency configuration maps.

Called during startup and runtime registration to catch config errors early
with clear messages instead of cryptic crashes during provisioning.
""".

-include_lib("kernel/include/logger.hrl").

-export([validate/1]).

-doc "Validate a dependency config. Returns ok or {error, [binary()]}.".
-spec validate(map()) -> ok | {error, [binary()]}.
validate(Config) when is_map(Config) ->
    Errors = lists:flatten([
        validate_required(Config),
        validate_adapter_fields(Config),
        validate_breaker_opts(Config),
        validate_bulkhead_opts(Config),
        validate_retry_opts(Config),
        validate_misc(Config)
    ]),
    case Errors of
        [] -> ok;
        _ -> {error, Errors}
    end;
validate(_) ->
    {error, [<<"dependency config must be a map">>]}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

validate_required(#{name := Name}) when is_atom(Name) ->
    [];
validate_required(#{name := Name}) ->
    [iolist_to_binary(io_lib:format("'name' must be an atom, got: ~p", [Name]))];
validate_required(_) ->
    [<<"missing required field 'name'">>].

validate_adapter_fields(Config) ->
    case resolve_adapter_type(Config) of
        kura ->
            case maps:is_key(repo, Config) of
                true -> [];
                false -> [<<"adapter 'kura' requires 'repo' field">>]
            end;
        brod ->
            Missing = [F || F <- [client, topic], not maps:is_key(F, Config)],
            [
                iolist_to_binary(io_lib:format("adapter 'brod' requires '~s' field", [F]))
             || F <- Missing
            ];
        pgo ->
            [];
        custom ->
            [];
        {unknown, Type} ->
            ?LOG_WARNING(#{msg => <<"Unknown dependency type">>, type => Type}),
            []
    end.

validate_breaker_opts(#{breaker := Opts}) when is_map(Opts) ->
    lists:flatten([
        validate_pos_integer(
            <<"breaker 'failure_threshold'">>, maps:get(failure_threshold, Opts, undefined)
        ),
        validate_pos_integer(
            <<"breaker 'wait_duration'">>, maps:get(wait_duration, Opts, undefined)
        ),
        validate_pos_integer(
            <<"breaker 'slow_call_duration'">>, maps:get(slow_call_duration, Opts, undefined)
        ),
        validate_pos_integer(
            <<"breaker 'half_open_requests'">>, maps:get(half_open_requests, Opts, undefined)
        )
    ]);
validate_breaker_opts(#{breaker := V}) ->
    [iolist_to_binary(io_lib:format("'breaker' must be a map, got: ~p", [V]))];
validate_breaker_opts(_) ->
    [].

validate_bulkhead_opts(#{bulkhead := Opts}) when is_map(Opts) ->
    validate_pos_integer(
        <<"bulkhead 'max_concurrent'">>, maps:get(max_concurrent, Opts, undefined)
    );
validate_bulkhead_opts(#{bulkhead := V}) ->
    [iolist_to_binary(io_lib:format("'bulkhead' must be a map, got: ~p", [V]))];
validate_bulkhead_opts(_) ->
    [].

validate_retry_opts(#{retry := Opts}) when is_map(Opts) ->
    lists:flatten([
        validate_pos_integer(<<"retry 'max_attempts'">>, maps:get(max_attempts, Opts, undefined)),
        validate_non_neg_integer(<<"retry 'base_delay'">>, maps:get(base_delay, Opts, undefined)),
        validate_non_neg_integer(<<"retry 'max_delay'">>, maps:get(max_delay, Opts, undefined))
    ]);
validate_retry_opts(#{retry := V}) ->
    [iolist_to_binary(io_lib:format("'retry' must be a map, got: ~p", [V]))];
validate_retry_opts(_) ->
    [].

validate_misc(Config) ->
    lists:flatten([
        validate_non_neg_integer(
            <<"'shutdown_priority'">>, maps:get(shutdown_priority, Config, undefined)
        ),
        validate_pos_integer(<<"'default_timeout'">>, maps:get(default_timeout, Config, undefined)),
        validate_boolean(<<"'critical'">>, maps:get(critical, Config, undefined))
    ]).

resolve_adapter_type(#{adapter := kura}) -> kura;
resolve_adapter_type(#{adapter := brod}) -> brod;
resolve_adapter_type(#{adapter := pgo}) -> pgo;
resolve_adapter_type(#{adapter := Mod}) when is_atom(Mod) -> custom;
resolve_adapter_type(#{type := database}) -> pgo;
resolve_adapter_type(#{type := kafka}) -> brod;
resolve_adapter_type(#{type := custom}) -> custom;
resolve_adapter_type(#{type := Type}) -> {unknown, Type};
resolve_adapter_type(_) -> custom.

validate_pos_integer(_Label, undefined) ->
    [];
validate_pos_integer(_Label, V) when is_integer(V), V > 0 -> [];
validate_pos_integer(Label, V) ->
    [iolist_to_binary(io_lib:format("~s must be a positive integer, got: ~p", [Label, V]))].

validate_non_neg_integer(_Label, undefined) ->
    [];
validate_non_neg_integer(_Label, V) when is_integer(V), V >= 0 -> [];
validate_non_neg_integer(Label, V) ->
    [iolist_to_binary(io_lib:format("~s must be a non-negative integer, got: ~p", [Label, V]))].

validate_boolean(_Label, undefined) ->
    [];
validate_boolean(_Label, true) ->
    [];
validate_boolean(_Label, false) ->
    [];
validate_boolean(Label, V) ->
    [iolist_to_binary(io_lib:format("~s must be a boolean, got: ~p", [Label, V]))].
