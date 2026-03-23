-module(nova_resilience_deadline_plugin).

-moduledoc """
Nova plugin for request deadline propagation.

Reads the `X-Request-Deadline` header on incoming requests and sets a seki
deadline. Clears the deadline after the request completes.

## Usage in routes

```erlang
#{prefix => ~"/api",
  plugins => [
      {pre_request, nova_resilience_deadline_plugin, #{default_timeout => 30000}},
      {post_request, nova_resilience_deadline_plugin, #{}}
  ],
  routes => [...]}
```

## Options

- `default_timeout` — Default deadline in ms if no header present
- `header` — Header name to read (default: `~"x-request-deadline"`)
- `propagate_response` — If `true`, sets `X-Deadline-Remaining` response header
""".

-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

pre_request(Req, _Env, Opts, State) ->
    Header = maps:get(header, Opts, ~"x-request-deadline"),
    case cowboy_req:header(Header, Req) of
        undefined ->
            case maps:get(default_timeout, Opts, undefined) of
                undefined -> ok;
                Timeout -> seki_deadline:set(Timeout)
            end;
        Value ->
            case seki_deadline:from_header(Value) of
                ok -> ok;
                {error, invalid_header} -> ok
            end
    end,
    {ok, Req, State}.

post_request(Req, _Env, Opts, State) ->
    case seki_deadline:reached() of
        true ->
            telemetry:execute(
                [nova_resilience, request, deadline_exceeded],
                #{},
                #{path => cowboy_req:path(Req), method => cowboy_req:method(Req)}
            );
        false ->
            ok
    end,
    Req1 =
        case maps:get(propagate_response, Opts, false) of
            true ->
                case seki_deadline:to_header() of
                    {ok, Remaining} ->
                        cowboy_req:set_resp_header(~"x-deadline-remaining", Remaining, Req);
                    undefined ->
                        Req
                end;
            false ->
                Req
        end,
    seki_deadline:clear(),
    {ok, Req1, State}.

plugin_info() ->
    #{
        title => ~"nova_resilience_deadline_plugin",
        version => ~"0.1.0",
        url => ~"https://github.com/Taure/nova_resilience",
        authors => [~"Nova Resilience"],
        description => ~"Deadline propagation for Nova requests"
    }.
