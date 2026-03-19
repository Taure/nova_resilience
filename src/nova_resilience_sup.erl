-module(nova_resilience_sup).

-moduledoc """
Top-level supervisor for nova_resilience.

Supervision tree:
```
nova_resilience_sup (one_for_one)
  ├── nova_resilience_registry (gen_server)
  └── nova_resilience_gate (gen_server)
```
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{
            id => nova_resilience_registry,
            start => {nova_resilience_registry, start_link, []},
            shutdown => 5000,
            type => worker
        },
        #{
            id => nova_resilience_gate,
            start => {nova_resilience_gate, start_link, []},
            shutdown => 5000,
            type => worker
        }
    ],
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, Children}}.
