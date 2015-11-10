%% Copyright (c) 2011-2014, Loïc Hoguin <essen@ninenines.eu>
%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(cowboy_protocol).

%% API.
-export([start_link/4]).

%% Internal.
-export([init/4]).
-export([parse_request/3]).
-export([resume/6]).

-type opts() :: [{compress, boolean()}
| {env, cowboy_middleware:env()}
| {max_empty_lines, non_neg_integer()}
| {max_header_name_length, non_neg_integer()}
| {max_header_value_length, non_neg_integer()}
| {max_headers, non_neg_integer()}
| {max_keepalive, non_neg_integer()}
| {max_request_line_length, non_neg_integer()}
| {middlewares, [module()]}
| {onresponse, cowboy:onresponse_fun()}
| {timeout, timeout()}].
-export_type([opts/0]).

-record(state, {
  socket :: inet:socket(),
  transport :: module(),
  middlewares :: [module()],
  compress :: boolean(),
  env :: cowboy_middleware:env(),
  onresponse = undefined :: undefined | cowboy:onresponse_fun(),
  max_empty_lines :: non_neg_integer(),
  req_keepalive = 1 :: non_neg_integer(),
  max_keepalive :: non_neg_integer(),
  max_request_line_length :: non_neg_integer(),
  max_header_name_length :: non_neg_integer(),
  max_header_value_length :: non_neg_integer(),
  max_headers :: non_neg_integer(),
  timeout :: timeout(),
  until :: non_neg_integer() | infinity
}).

-include_lib("cowlib/include/cow_inline.hrl").
-include_lib("cowlib/include/cow_parse.hrl").

%% API.

-spec start_link(ranch:ref(), inet:socket(), module(), opts()) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
  Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
  {ok, Pid}.

%% Internal.

%% Faster alternative to proplists:get_value/3.
get_value(Key, Opts, Default) ->
  case lists:keyfind(Key, 1, Opts) of
    {_, Value} -> Value;
    _ -> Default
  end.

-spec init(ranch:ref(), inet:socket(), module(), opts()) -> ok.
init(Ref, Socket, Transport, Opts) ->
  ok = ranch:accept_ack(Ref),
  Timeout = get_value(timeout, Opts, 5000),
  Until = until(Timeout),
  case recv(Socket, Transport, Until) of
    {ok, Data} ->
      OnFirstRequest = get_value(onfirstrequest, Opts, undefined),
      case OnFirstRequest of
        undefined -> ok;
        _ -> OnFirstRequest(Ref, Socket, Transport, Opts)
      end,
      Compress = get_value(compress, Opts, false),
      MaxEmptyLines = get_value(max_empty_lines, Opts, 5),
      MaxHeaderNameLength = get_value(max_header_name_length, Opts, 64),
      MaxHeaderValueLength = get_value(max_header_value_length, Opts, 4096),
      MaxHeaders = get_value(max_headers, Opts, 100),
      MaxKeepalive = get_value(max_keepalive, Opts, 100),
      MaxRequestLineLength = get_value(max_request_line_length, Opts, 4096),
      Middlewares = get_value(middlewares, Opts, [cowboy_router, cowboy_handler]),
      Env = [{listener, Ref} | get_value(env, Opts, [])],
      OnResponse = get_value(onresponse, Opts, undefined),
      parse_request(Data, #state{socket = Socket, transport = Transport,
        middlewares = Middlewares, compress = Compress, env = Env,
        max_empty_lines = MaxEmptyLines, max_keepalive = MaxKeepalive,
        max_request_line_length = MaxRequestLineLength,
        max_header_name_length = MaxHeaderNameLength,
        max_header_value_length = MaxHeaderValueLength, max_headers = MaxHeaders,
        onresponse = OnResponse, timeout = Timeout, until = Until}, 0);
    {error, _} ->
      terminate(#state{socket = Socket, transport = Transport}) %% @todo ridiculous
  end.

-spec until(timeout()) -> non_neg_integer() | infinity.
until(infinity) ->
  infinity;
until(Timeout) ->
  erlang:monotonic_time(milli_seconds) + Timeout.

%% Request parsing.
%%
%% The next set of functions is the request parsing code. All of it
%% runs using a single binary match context. This optimization ends
%% right after the header parsing is finished and the code becomes
%% more interesting past that point.

-spec recv(inet:socket(), module(), non_neg_integer() | infinity)
      -> {ok, binary()} | {error, closed | timeout | atom()}.
recv(Socket, Transport, infinity) ->
  Transport:recv(Socket, 0, infinity);
recv(Socket, Transport, Until) ->
  Timeout = Until - erlang:monotonic_time(milli_seconds),
  if Timeout < 0 ->
    {error, timeout};
    true ->
      Transport:recv(Socket, 0, Timeout)
  end.

-spec wait_request(binary(), #state{}, non_neg_integer()) -> ok.
wait_request(Buffer, State = #state{socket = Socket, transport = Transport,
  until = Until}, ReqEmpty) ->
  case recv(Socket, Transport, Until) of
    {ok, Data} ->
      parse_request(<<Buffer/binary, Data/binary>>, State, ReqEmpty);
    {error, _} ->
      terminate(State)
  end.

-spec parse_request(binary(), #state{}, non_neg_integer()) -> ok.
%% Empty lines must be using \r\n.
parse_request(<<"PROXY ", Data/binary>>,
    State = #state{socket = Socket, transport = Transport, until = Until}, ReqEmpty) ->
  {Proxy, Other} = case binary:split(Data, [<<"\r\n">>]) of
                     [P, O] -> {P, O};
                     [P] -> {P, <<>>}
                   end,
  case parse_proxy_protocol(Proxy) of
    unknown_peer when Other =:= <<>> ->
      {ok, NewData} = recv(Socket, Transport, Until),
      parse_request(NewData, State, ReqEmpty),
      {ok, State};
    unknown_peer ->
      parse_request(Other, State, ReqEmpty),
      {ok, State};
    not_proxy_protocol ->
      Transport:close(Socket),
      throw(not_proxy_protocol);
    ProxyInfo when Other =:= <<>> ->
      put(proxy, ProxyInfo),
      {ok, NewData} = recv(Socket, Transport, Until),
      parse_request(NewData, State, ReqEmpty);
    ProxyInfo ->
      put(proxy, ProxyInfo),
      parse_request(Other, State, ReqEmpty)
  end;
parse_request(<<$\n, _/bits>>, State, _) ->
  error_terminate(400, State);
parse_request(<<$\s, _/bits>>, State, _) ->
  error_terminate(400, State);
%% We limit the length of the Request-line to MaxLength to avoid endlessly
%% reading from the socket and eventually crashing.
parse_request(Buffer, State = #state{max_request_line_length = MaxLength,
  max_empty_lines = MaxEmpty}, ReqEmpty) ->
  case match_eol(Buffer, 0) of
    nomatch when byte_size(Buffer) > MaxLength ->
      error_terminate(414, State);
    nomatch ->
      wait_request(Buffer, State, ReqEmpty);
    1 when ReqEmpty =:= MaxEmpty ->
      error_terminate(400, State);
    1 ->
      <<_:16, Rest/bits>> = Buffer,
      parse_request(Rest, State, ReqEmpty + 1);
    _ ->
      parse_method(Buffer, State, <<>>)
  end.

match_eol(<<$\n, _/bits>>, N) ->
  N;
match_eol(<<_, Rest/bits>>, N) ->
  match_eol(Rest, N + 1);
match_eol(_, _) ->
  nomatch.

parse_method(<<C, Rest/bits>>, State, SoFar) ->
  case C of
    $\r -> error_terminate(400, State);
    $\s -> parse_uri(Rest, State, SoFar);
    _ -> parse_method(Rest, State, <<SoFar/binary, C>>)
  end.

parse_uri(<<$\r, _/bits>>, State, _) ->
  error_terminate(400, State);
parse_uri(<<$\s, _/bits>>, State, _) ->
  error_terminate(400, State);
parse_uri(<<"* ", Rest/bits>>, State, Method) ->
  parse_version(Rest, State, Method, <<"*">>, <<>>);
parse_uri(<<"http://", Rest/bits>>, State, Method) ->
  parse_uri_skip_host(Rest, State, Method);
parse_uri(<<"https://", Rest/bits>>, State, Method) ->
  parse_uri_skip_host(Rest, State, Method);
parse_uri(<<"HTTP://", Rest/bits>>, State, Method) ->
  parse_uri_skip_host(Rest, State, Method);
parse_uri(<<"HTTPS://", Rest/bits>>, State, Method) ->
  parse_uri_skip_host(Rest, State, Method);
parse_uri(Buffer, State, Method) ->
  parse_uri_path(Buffer, State, Method, <<>>).

parse_uri_skip_host(<<C, Rest/bits>>, State, Method) ->
  case C of
    $\r -> error_terminate(400, State);
    $/ -> parse_uri_path(Rest, State, Method, <<"/">>);
    $\s -> parse_version(Rest, State, Method, <<"/">>, <<>>);
    $? -> parse_uri_query(Rest, State, Method, <<"/">>, <<>>);
    $# -> skip_uri_fragment(Rest, State, Method, <<"/">>, <<>>);
    _ -> parse_uri_skip_host(Rest, State, Method)
  end.

parse_uri_path(<<C, Rest/bits>>, State, Method, SoFar) ->
  case C of
    $\r -> error_terminate(400, State);
    $\s -> parse_version(Rest, State, Method, SoFar, <<>>);
    $? -> parse_uri_query(Rest, State, Method, SoFar, <<>>);
    $# -> skip_uri_fragment(Rest, State, Method, SoFar, <<>>);
    _ -> parse_uri_path(Rest, State, Method, <<SoFar/binary, C>>)
  end.

parse_uri_query(<<C, Rest/bits>>, S, M, P, SoFar) ->
  case C of
    $\r -> error_terminate(400, S);
    $\s -> parse_version(Rest, S, M, P, SoFar);
    $# -> skip_uri_fragment(Rest, S, M, P, SoFar);
    _ -> parse_uri_query(Rest, S, M, P, <<SoFar/binary, C>>)
  end.

skip_uri_fragment(<<C, Rest/bits>>, S, M, P, Q) ->
  case C of
    $\r -> error_terminate(400, S);
    $\s -> parse_version(Rest, S, M, P, Q);
    _ -> skip_uri_fragment(Rest, S, M, P, Q)
  end.

parse_version(<<"HTTP/1.1\r\n", Rest/bits>>, S, M, P, Q) ->
  parse_header(Rest, S, M, P, Q, 'HTTP/1.1', []);
parse_version(<<"HTTP/1.0\r\n", Rest/bits>>, S, M, P, Q) ->
  parse_header(Rest, S, M, P, Q, 'HTTP/1.0', []);
parse_version(_, State, _, _, _) ->
  error_terminate(505, State).

%% Stop receiving data if we have more than allowed number of headers.
wait_header(_, State = #state{max_headers = MaxHeaders}, _, _, _, _, Headers)
  when length(Headers) >= MaxHeaders ->
  error_terminate(400, State);
wait_header(Buffer, State = #state{socket = Socket, transport = Transport,
  until = Until}, M, P, Q, V, H) ->
  case recv(Socket, Transport, Until) of
    {ok, Data} ->
      parse_header(<<Buffer/binary, Data/binary>>,
        State, M, P, Q, V, H);
    {error, timeout} ->
      error_terminate(408, State);
    {error, _} ->
      terminate(State)
  end.

parse_header(<<$\r, $\n, Rest/bits>>, S, M, P, Q, V, Headers) ->
  request(Rest, S, M, P, Q, V, lists:reverse(Headers));
parse_header(Buffer, State = #state{max_header_name_length = MaxLength},
    M, P, Q, V, H) ->
  case match_colon(Buffer, 0) of
    nomatch when byte_size(Buffer) > MaxLength ->
      error_terminate(400, State);
    nomatch ->
      wait_header(Buffer, State, M, P, Q, V, H);
    _ ->
      parse_hd_name(Buffer, State, M, P, Q, V, H, <<>>)
  end.

match_colon(<<$:, _/bits>>, N) ->
  N;
match_colon(<<_, Rest/bits>>, N) ->
  match_colon(Rest, N + 1);
match_colon(_, _) ->
  nomatch.

parse_hd_name(<<$:, Rest/bits>>, S, M, P, Q, V, H, SoFar) ->
  parse_hd_before_value(Rest, S, M, P, Q, V, H, SoFar);
parse_hd_name(<<C, Rest/bits>>, S, M, P, Q, V, H, SoFar) when ?IS_WS(C) ->
  parse_hd_name_ws(Rest, S, M, P, Q, V, H, SoFar);
parse_hd_name(<<C, Rest/bits>>, S, M, P, Q, V, H, SoFar) ->
  ?LOWER(parse_hd_name, Rest, S, M, P, Q, V, H, SoFar).

parse_hd_name_ws(<<C, Rest/bits>>, S, M, P, Q, V, H, Name) ->
  case C of
    $\s -> parse_hd_name_ws(Rest, S, M, P, Q, V, H, Name);
    $\t -> parse_hd_name_ws(Rest, S, M, P, Q, V, H, Name);
    $: -> parse_hd_before_value(Rest, S, M, P, Q, V, H, Name)
  end.

wait_hd_before_value(Buffer, State = #state{
  socket = Socket, transport = Transport, until = Until},
    M, P, Q, V, H, N) ->
  case recv(Socket, Transport, Until) of
    {ok, Data} ->
      parse_hd_before_value(<<Buffer/binary, Data/binary>>,
        State, M, P, Q, V, H, N);
    {error, timeout} ->
      error_terminate(408, State);
    {error, _} ->
      terminate(State)
  end.

parse_hd_before_value(<<$\s, Rest/bits>>, S, M, P, Q, V, H, N) ->
  parse_hd_before_value(Rest, S, M, P, Q, V, H, N);
parse_hd_before_value(<<$\t, Rest/bits>>, S, M, P, Q, V, H, N) ->
  parse_hd_before_value(Rest, S, M, P, Q, V, H, N);
parse_hd_before_value(Buffer, State = #state{
  max_header_value_length = MaxLength}, M, P, Q, V, H, N) ->
  case match_eol(Buffer, 0) of
    nomatch when byte_size(Buffer) > MaxLength ->
      error_terminate(400, State);
    nomatch ->
      wait_hd_before_value(Buffer, State, M, P, Q, V, H, N);
    _ ->
      parse_hd_value(Buffer, State, M, P, Q, V, H, N, <<>>)
  end.

%% We completely ignore the first argument which is always
%% the empty binary. We keep it there because we don't want
%% to change the other arguments' position and trigger costy
%% operations for no reasons.
wait_hd_value(_, State = #state{
  socket = Socket, transport = Transport, until = Until},
    M, P, Q, V, H, N, SoFar) ->
  case recv(Socket, Transport, Until) of
    {ok, Data} ->
      parse_hd_value(Data, State, M, P, Q, V, H, N, SoFar);
    {error, timeout} ->
      error_terminate(408, State);
    {error, _} ->
      terminate(State)
  end.

%% Pushing back as much as we could the retrieval of new data
%% to check for multilines allows us to avoid a few tests in
%% the critical path, but forces us to have a special function.
wait_hd_value_nl(_, State = #state{
  socket = Socket, transport = Transport, until = Until},
    M, P, Q, V, Headers, Name, SoFar) ->
  case recv(Socket, Transport, Until) of
    {ok, <<C, Data/bits>>} when C =:= $\s; C =:= $\t ->
      parse_hd_value(Data, State, M, P, Q, V, Headers, Name, SoFar);
    {ok, Data} ->
      parse_header(Data, State, M, P, Q, V, [{Name, SoFar} | Headers]);
    {error, timeout} ->
      error_terminate(408, State);
    {error, _} ->
      terminate(State)
  end.

parse_hd_value(<<$\r, Rest/bits>>, S, M, P, Q, V, Headers, Name, SoFar) ->
  case Rest of
    <<$\n>> ->
      wait_hd_value_nl(<<>>, S, M, P, Q, V, Headers, Name, SoFar);
    <<$\n, C, Rest2/bits>> when C =:= $\s; C =:= $\t ->
      parse_hd_value(Rest2, S, M, P, Q, V, Headers, Name,
        <<SoFar/binary, C>>);
    <<$\n, Rest2/bits>> ->
      parse_header(Rest2, S, M, P, Q, V, [{Name, clean_value_ws_end(SoFar, byte_size(SoFar) - 1)} | Headers])
  end;
parse_hd_value(<<C, Rest/bits>>, S, M, P, Q, V, H, N, SoFar) ->
  parse_hd_value(Rest, S, M, P, Q, V, H, N, <<SoFar/binary, C>>);
parse_hd_value(<<>>, State = #state{max_header_value_length = MaxLength},
    _, _, _, _, _, _, SoFar) when byte_size(SoFar) > MaxLength ->
  error_terminate(400, State);
parse_hd_value(<<>>, S, M, P, Q, V, H, N, SoFar) ->
  wait_hd_value(<<>>, S, M, P, Q, V, H, N, SoFar).

clean_value_ws_end(_, -1) ->
  <<>>;
clean_value_ws_end(Value, N) ->
  case binary:at(Value, N) of
    $\s -> clean_value_ws_end(Value, N - 1);
    $\t -> clean_value_ws_end(Value, N - 1);
    _ ->
      S = N + 1,
      <<Value2:S/binary, _/bits>> = Value,
      Value2
  end.

-ifdef(TEST).
clean_value_ws_end_test_() ->
  Tests = [
    {<<>>, <<>>},
    {<<"     ">>, <<>>},
    {<<"text/*;q=0.3, text/html;q=0.7, text/html;level=1, "
    "text/html;level=2;q=0.4, */*;q=0.5   \t   \t    ">>,
      <<"text/*;q=0.3, text/html;q=0.7, text/html;level=1, "
      "text/html;level=2;q=0.4, */*;q=0.5">>}
  ],
  [{V, fun() -> R = clean_value_ws_end(V, byte_size(V) - 1) end} || {V, R} <- Tests].
-endif.

-ifdef(PERF).
horse_clean_value_ws_end() ->
  horse:repeat(200000,
    clean_value_ws_end(
      <<"text/*;q=0.3, text/html;q=0.7, text/html;level=1, "
      "text/html;level=2;q=0.4, */*;q=0.5          ">>,
      byte_size(<<"text/*;q=0.3, text/html;q=0.7, text/html;level=1, "
      "text/html;level=2;q=0.4, */*;q=0.5          ">>) - 1)
  ).
-endif.

request(B, State = #state{transport = Transport}, M, P, Q, Version, Headers) ->
  case lists:keyfind(<<"host">>, 1, Headers) of
    false when Version =:= 'HTTP/1.1' ->
      error_terminate(400, State);
    false ->
      request(B, State, M, P, Q, Version, Headers,
        <<>>, default_port(Transport:name()));
    {_, RawHost} ->
      try parse_host(RawHost, false, <<>>) of
        {Host, undefined} ->
          request(B, State, M, P, Q, Version, Headers,
            Host, default_port(Transport:name()));
        {Host, Port} ->
          request(B, State, M, P, Q, Version, Headers,
            Host, Port)
      catch _:_ ->
        error_terminate(400, State)
      end
  end.

-spec default_port(atom()) -> 80 | 443.
default_port(ssl) -> 443;
default_port(_) -> 80.

%% Same code as cow_http:parse_fullhost/1, but inline because we
%% really want this to go fast.
parse_host(<<$[, Rest/bits>>, false, <<>>) ->
  parse_host(Rest, true, <<$[>>);
parse_host(<<>>, false, Acc) ->
  {Acc, undefined};
parse_host(<<$:, Rest/bits>>, false, Acc) ->
  {Acc, list_to_integer(binary_to_list(Rest))};
parse_host(<<$], Rest/bits>>, true, Acc) ->
  parse_host(Rest, false, <<Acc/binary, $]>>);
parse_host(<<C, Rest/bits>>, E, Acc) ->
  ?LOWER(parse_host, Rest, E, Acc).

%% End of request parsing.
%%
%% We create the Req object and start handling the request.

request(Buffer, State = #state{socket = Socket, transport = Transport,
  req_keepalive = ReqKeepalive, max_keepalive = MaxKeepalive,
  compress = Compress, onresponse = OnResponse},
    Method, Path, Query, Version, Headers, Host, Port) ->
  case Transport:peername(Socket) of
    {ok, Peer} ->
      Req = cowboy_req:new(Socket, Transport, Peer, Method, Path,
        Query, Version, Headers, Host, Port, Buffer,
        ReqKeepalive < MaxKeepalive, Compress, OnResponse),
      execute(Req, State);
    {error, _} ->
      %% Couldn't read the peer address; connection is gone.
      terminate(State)
  end.

-spec execute(cowboy_req:req(), #state{}) -> ok.
execute(Req, State = #state{middlewares = Middlewares, env = Env}) ->
  execute(Req, State, Env, Middlewares).

-spec execute(cowboy_req:req(), #state{}, cowboy_middleware:env(), [module()])
      -> ok.
execute(Req, State, Env, []) ->
  next_request(Req, State, get_value(result, Env, ok));
execute(Req, State, Env, [Middleware | Tail]) ->
  case Middleware:execute(Req, Env) of
    {ok, Req2, Env2} ->
      execute(Req2, State, Env2, Tail);
    {suspend, Module, Function, Args} ->
      erlang:hibernate(?MODULE, resume,
        [State, Env, Tail, Module, Function, Args]);
    {stop, Req2} ->
      next_request(Req2, State, ok)
  end.

-spec resume(#state{}, cowboy_middleware:env(), [module()],
    module(), module(), [any()]) -> ok.
resume(State, Env, Tail, Module, Function, Args) ->
  case apply(Module, Function, Args) of
    {ok, Req2, Env2} ->
      execute(Req2, State, Env2, Tail);
    {suspend, Module2, Function2, Args2} ->
      erlang:hibernate(?MODULE, resume,
        [State, Env, Tail, Module2, Function2, Args2]);
    {stop, Req2} ->
      next_request(Req2, State, ok)
  end.

-spec next_request(cowboy_req:req(), #state{}, any()) -> ok.
next_request(Req, State = #state{req_keepalive = Keepalive, timeout = Timeout},
    HandlerRes) ->
  cowboy_req:ensure_response(Req, 204),
  %% If we are going to close the connection,
  %% we do not want to attempt to skip the body.
  case cowboy_req:get(connection, Req) of
    close ->
      terminate(State);
    _ ->
      %% Skip the body if it is reasonably sized. Close otherwise.
      Buffer = case cowboy_req:body(Req) of
                 {ok, _, Req2} -> cowboy_req:get(buffer, Req2);
                 _ -> close
               end,
      %% Flush the resp_sent message before moving on.
      if HandlerRes =:= ok, Buffer =/= close ->
        receive {cowboy_req, resp_sent} -> ok after 0 -> ok end,
        ?MODULE:parse_request(Buffer,
          State#state{req_keepalive = Keepalive + 1,
            until = until(Timeout)}, 0);
        true ->
          terminate(State)
      end
  end.

-spec error_terminate(cowboy:http_status(), #state{}) -> ok.
error_terminate(Status, State = #state{socket = Socket, transport = Transport,
  compress = Compress, onresponse = OnResponse}) ->
  error_terminate(Status, cowboy_req:new(Socket, Transport,
    undefined, <<"GET">>, <<>>, <<>>, 'HTTP/1.1', [], <<>>,
    undefined, <<>>, false, Compress, OnResponse), State).

-spec error_terminate(cowboy:http_status(), cowboy_req:req(), #state{}) -> ok.
error_terminate(Status, Req, State) ->
  _ = cowboy_req:reply(Status, Req),
  terminate(State).

-spec terminate(#state{}) -> ok.
terminate(#state{socket = Socket, transport = Transport}) ->
  Transport:close(Socket),
  ok.


parse_proxy_protocol(<<"TCP", Proto:1/binary, _:1/binary, Info/binary>>) ->
  InfoStr = binary_to_list(Info),
  case string:tokens(InfoStr, " \r\n") of
    [SourceAddress, DestAddress, SourcePort, DestPort] ->
      case {parse_inet(Proto), parse_ips([SourceAddress, DestAddress], []),
        parse_ports([SourcePort, DestPort], [])} of
        {ProtoParsed, [SourceInetAddress, DestInetAddress], [SourceInetPort, DestInetPort]} ->
          {ProtoParsed, SourceInetAddress, DestInetAddress, SourceInetPort, DestInetPort};
        _ ->
          malformed_proxy_protocol
      end
  end;
parse_proxy_protocol(<<"UNKNOWN", _/binary>>) ->
  unknown_peer;
parse_proxy_protocol(_) ->
  not_proxy_protocol.

parse_inet(<<"4">>) ->
  ipv4;
parse_inet(<<"6">>) ->
  ipv6;
parse_inet(_) ->
  {error, invalid_inet_version}.

parse_ports([], Retval) ->
  Retval;
parse_ports([Port | Ports], Retval) ->
  try list_to_integer(Port) of
    IntPort ->
      parse_ports(Ports, Retval ++ [IntPort])
  catch
    error:badarg ->
      {error, invalid_port}
  end.

parse_ips([], Retval) ->
  Retval;
parse_ips([Ip | Ips], Retval) ->
  case inet:parse_address(Ip) of
    {ok, ParsedIp} ->
      parse_ips(Ips, Retval ++ [ParsedIp]);
    _ ->
      {error, invalid_address}
  end.
