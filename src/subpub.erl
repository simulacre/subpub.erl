-module(subpub).
-export([listen/0, listen/1, procmsgs/1, handle_client/1]).

-define(TCP_OPTIONS, [binary, {packet, 0}, {active, false}, {reuseaddr, true}]).

listen() ->
  listen(8888).

listen(Port) ->
  {ok, LSocket} = gen_tcp:listen(Port, ?TCP_OPTIONS),
  register(broadcaster, spawn(?MODULE, procmsgs, [[]])),
  accept(LSocket).

procmsgs(Connections) ->
  receive
    {publish, Topic, Msg} ->
      [C ! {publish, Topic, Msg} || C <- Connections],
      procmsgs(Connections);
    {register, Proc} ->
      procmsgs([Proc|Connections]);
    Other ->
      io:format("received unrecognized message: ~p.~n", [Other]),
      procmsgs(Connections)
  end.

accept(LSocket) ->
    {ok, Socket} = gen_tcp:accept(LSocket),
    broadcaster ! {register, spawn(?MODULE, handle_client, [Socket])},
    accept(LSocket).

handle_client(Client) ->
  put(subs, []),
  put(psubs, []),
  loop_client(Client).

loop_client(Client) ->
    case gen_tcp:recv(Client, 0, 100) of
        {ok, Data} ->
          io:format("recv: ~p.~n", [Data]),
          [{command, Command} | Rest] = redis_cmd_parser:parse(binary_to_list(Data)),
          Reply = procmd(Client, Command, Rest),
          io:format("resp: ~p.~n", [Reply]),
          tell_client(Client, Reply),
          loop_client(Client);
        {error, timeout} ->
          receive
            {publish, Topic, Msg} -> 
              case lists:any(fun(E) -> E == Topic end, get(subs)) of
                  true ->
                      tell_client(Client, Msg);
                  _ -> nothing
              end,
              loop_client(Client)
          after 100 ->
              loop_client(Client)
          end;
        {error, closed} ->
          ok;
        {error, Reason} ->
          io:format("failed: ~p.~n", [Reason])
    end.


procmd(_Client, "PUBLISH", [{topic, Topic}, {msg, Msg}]) ->
  broadcaster ! {publish, Topic, Msg},
  "ok";

procmd(Client, "SUBSCRIBE", [{topics, Topics}]) ->
  io:format("SUBSCRIBE ~p.~n", [Topics]),
  lists:foldl(
    fun(Topic, Reply) -> string:concat(Reply, subscribe(Client, Topic)) end, 
    "", 
    Topics);

procmd(Client, "SHUTDOWN", _) ->
  tell_client(Client, "ok"),
  halt();

procmd(_Client, Command, _Args) ->
  string:concat("unrecognized command ", Command).

subscribe(_Client, Topic) ->
  io:format("subscribe ~p.~n", [Topic]),
  put(subs, [Topic|get(subs)]),
  Cnt = length(get(subs)),
  lists:foldl(fun(E, Sum) -> string:concat(Sum, E) end, "*3\r\n$9\r\nsubscribe\r\n$", 
    [ integer_to_list(length(Topic)),
      "\r\n",
      Topic,
      "\r\n:",
      integer_to_list(Cnt),
      "\r\n"
    ]).

tell_client(Client, Msg) ->
  gen_tcp:send(Client, list_to_binary(string:concat(Msg, "\r\n"))).
