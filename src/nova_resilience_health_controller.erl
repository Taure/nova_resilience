-module(nova_resilience_health_controller).

-moduledoc """
Nova controller for health, readiness, and liveness endpoints.

Registered automatically when `nova_resilience` is included in `nova_apps`.

- `GET /health` — Full health report with dependency status
- `GET /ready` — Readiness probe (503 if critical deps unhealthy)
- `GET /live` — Liveness probe (503 if process unresponsive)
""".

-export([health/1, ready/1, live/1]).
-export([build_health_report/0]).

-define(HEALTH_NAME, nova_resilience_health).

-doc "Full health report with dependency status and VM info.".
health(#{method := <<"GET">>} = _Req) ->
    Report = build_health_report(),
    telemetry:execute(
        [nova_resilience, health, check],
        #{check_count => map_size(maps:get(dependencies, Report, #{}))},
        Report
    ),
    {json, Report}.

-doc "Readiness probe. Returns 200 when ready, 503 otherwise.".
ready(#{method := <<"GET">>} = _Req) ->
    case nova_resilience_gate:is_ready() of
        true ->
            {json, #{status => <<"ready">>}};
        false ->
            {json, 503, #{}, #{status => <<"not_ready">>}}
    end.

-doc "Liveness probe. Returns 200 if the process is responsive.".
live(#{method := <<"GET">>} = _Req) ->
    {json, #{status => <<"alive">>}}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-doc "Build the full health report. Used by the controller and `nova_resilience:health/0`.".
-spec build_health_report() -> map().
build_health_report() ->
    HealthResult = seki_health:check(?HEALTH_NAME),
    Deps = nova_resilience_registry:list(),
    DepStatuses = lists:foldl(
        fun(#{name := Name} = _Dep, Acc) ->
            Status =
                case nova_resilience_registry:status(Name) of
                    {ok, S} -> S;
                    _ -> #{breaker => unknown, bulkhead => unknown}
                end,
            DepHealth = dep_health_from_check(Name, HealthResult),
            Acc#{Name => maps:merge(DepHealth, Status)}
        end,
        #{},
        Deps
    ),
    OverallStatus =
        case nova_resilience_gate:is_ready() of
            true -> <<"healthy">>;
            false -> <<"unhealthy">>
        end,
    #{
        status => OverallStatus,
        dependencies => DepStatuses,
        vm => vm_info()
    }.

dep_health_from_check(Name, #{checks := Checks}) ->
    case maps:get(Name, Checks, undefined) of
        {healthy, Details} -> #{status => <<"healthy">>, details => Details};
        {degraded, Details} -> #{status => <<"degraded">>, details => Details};
        {unhealthy, Details} -> #{status => <<"unhealthy">>, details => Details};
        undefined -> #{status => <<"unknown">>}
    end.

vm_info() ->
    #{
        memory_mb => erlang:memory(total) div (1024 * 1024),
        process_count => erlang:system_info(process_count),
        run_queue => erlang:statistics(run_queue)
    }.
