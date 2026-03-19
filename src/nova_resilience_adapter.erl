-module(nova_resilience_adapter).

-moduledoc """
Behaviour for dependency type adapters.

Adapters provide built-in health checks, call wrapping, and shutdown logic
for known dependency types (database, kafka, etc.). Implement this behaviour
for custom dependency types.

## Built-in adapters

- `nova_resilience_adapter_pgo` — PostgreSQL via pgo (default for `database` type)
- `nova_resilience_adapter_kura` — PostgreSQL via kura
- `nova_resilience_adapter_brod` — Kafka via brod
""".

-doc "Check if the dependency is healthy.".
-callback health_check(Config :: map()) -> ok | {error, term()}.

-doc "Wrap a function call with adapter-specific logic.".
-callback wrap_call(Config :: map(), fun(() -> term())) -> term().

-doc "Perform adapter-specific shutdown cleanup.".
-callback shutdown(Config :: map()) -> ok.
