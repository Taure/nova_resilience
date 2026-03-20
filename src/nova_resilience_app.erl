-module(nova_resilience_app).

-moduledoc """
Application behaviour for nova_resilience.

Starts the supervision tree containing the dependency registry and readiness gate.
Shutdown is automatic via `prep_stop/1` — no manual calls needed.
""".

-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

start(_StartType, _StartArgs) ->
    nova_resilience_telemetry:attach(),
    nova_resilience_sup:start_link().

prep_stop(State) ->
    nova_resilience_shutdown:execute(),
    State.

stop(_State) ->
    ok.
