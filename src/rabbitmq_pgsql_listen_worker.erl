-module(rabbitmq_pgsql_listen_worker).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("rabbitmq_pgsql_listen.hrl").

%---------------------------
% Worker Startup
% --------------------------

start_link() ->
  gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
  register(rabbitmq_pgsql_listen, self()),
  rabbit_log:info("rabbitmq-pgsql-listen-exchange worker: started (~p)~n", [self()]),
  {ok,  {state, {dict:new(), []}}}.

%---------------------------
% Gen Server Implementation
% --------------------------
code_change(_, State, _) ->
  {ok, State}.

handle_call({create, X}, _From, State) ->
  connect_pgsql_client(X, State);

handle_call({delete, X, Bs}, _From, {state, {Cs, Xs}}) ->
  NXs = remove_binding(X, Cs, Xs, Bs),
  NCs = rabbitmq_pgsql_listen_lib:close_pgsql_client(X, Cs),
  {reply, ok, {state, {NCs, NXs}}};

handle_call({validate, X}, _From, State) ->
  connect_pgsql_client(X, State);

handle_call(_Msg, _From, _State) ->
  {noreply, unknown_command, _State}.

handle_cast({add_binding, X, B}, {state, {Cs, Xs}}) ->
  case rabbitmq_pgsql_listen_lib:pgsql_listen(X, B, Cs, Xs) of
    {ok, NXs} ->
      {noreply, {state, {Cs, NXs}}};
    _ ->
      {noreply, {state, {Cs, Xs}}}
  end;

handle_cast({remove_bindings, X, Bs}, {state, {Cs, Xs}}) ->
  NXs = remove_binding(X, Cs, Xs, Bs),
  {noreply, {state, {Cs, NXs}}};

handle_cast(Cast, State) ->
  rabbit_log:info("Unknown handle_cast: ~p, ~p~n", [Cast, State]),
  {noreply, State}.

handle_info({pgsql, Conn, {notification, Channel, _, Payload}}, {state, {Cs, Xs}}) ->
  rabbitmq_pgsql_listen_lib:publish_notification(Conn, Channel, Payload, Xs),
  {noreply, {state, {Cs, Xs}}};

handle_info(Message, State) ->
  rabbit_log:info("unknown handle_info: ~p~n", Message),
  {noreply, State}.

terminate(_,_) ->
  ok.

%-----------------
% Internal Methods
%-----------------

connect_pgsql_client(X, {state, {Cs, Xs}}) ->
  case rabbitmq_pgsql_listen_lib:get_pgsql_client(X, Cs) of
    {ok, NCs, _} ->
      {reply, ok, {state, {NCs, Xs}}};
    {error, Reason} ->
      {reply, {error, Reason}, {state, {Cs, Xs}}}
  end.

remove_binding(_, _, Xs, []) ->
  Xs;

remove_binding(X, Cs, Xs, [B | ListTail]) ->
  case rabbitmq_pgsql_listen_lib:pgsql_unlisten(X, B, Cs, Xs) of
    {ok, []} -> [];
    {ok, NXs} -> remove_binding(X, Cs, NXs, ListTail);
    error -> Xs
  end.
