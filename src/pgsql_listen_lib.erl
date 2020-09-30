%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2014-2020 AWeber Communications
%% @end
%%==============================================================================

%% @doc Methods to abstract away working with state, postgresql, and
%% amqp connections to minimize the amount of code in pgsql_listen_worker
%% @end

-module(pgsql_listen_lib).

-export([
    add_binding/3,
    publish_notification/4,
    remove_bindings/3,
    start_exchange/2,
    stop_exchange/2,
    validate_pgsql_connection/1
]).

-include("pgsql_listen.hrl").

%% @spec add_binding(X, B, State) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       Key    = binary()
%%       State  = #pgsql_listen_state
%%       Result = {ok, #pgsql_listen_state}|{error, Error}
%% @doc Add a binding to the exchange
%% @end
%%
add_binding(
    #exchange{name = Name},
    #binding{key = Key, source = {resource, _, exchange, _}},
    State = #pgsql_listen_state{channels = Cs, pgsql = PgSQL}
) ->
    case ensure_channel_binding_references(binary_to_list(Key), Name, Cs) of
        {ok, NCs} ->
            case listen_to_pgsql_channel(Name, binary_to_list(Key), PgSQL) of
                ok ->
                    {ok, State#pgsql_listen_state{channels = NCs}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% @spec start_exchange(X, State) -> #pgsql_listen_state
%% @where
%%       Conn    = pid()
%%       Channel = list()
%%       X      = rabbit_types:exchange()
%%       State  = #pgsql_listen_state
%%       Result = {ok, #pgsql_listen_state}|{error, Error}
%% @doc Publish a notification received from postgresql for the specified
%%       Channel to the bound exchange
%% @end
%%
publish_notification(Conn, Channel, Payload, State) ->
    Connection = dict:filter(
        fun(_, V) -> V#pgsql_listen_conn.pid == Conn end,
        State#pgsql_listen_state.pgsql
    ),

    [Key] = dict:fetch_keys(Connection),
    {resource, VHost, exchange, X} = Key,

    Value = dict:fetch(Key, Connection),

    Headers = [
        {<<"postgres-channel">>, longstr, Channel},
        {<<"postgres-dbname">>, longstr, Value#pgsql_listen_conn.dbname},
        {<<"postgres-server">>, longstr, Value#pgsql_listen_conn.server},
        {<<"source-exchange">>, longstr, X}
    ],

    Properties = #properties{
        content_encoding = get_binding_longstr(Key, Channel, <<"content_encoding">>),
        content_type = get_binding_longstr(Key, Channel, <<"content_type">>),
        delivery_mode = get_delivery_mode(Key, Channel),
        headers = Headers,
        priority = get_binding_long(Key, Channel, <<"priority">>),
        reply_to = get_binding_longstr(Key, Channel, <<"reply_to">>),
        type = get_binding_longstr(Key, Channel, <<"type">>)
    },

    case ensure_amqp_connection(VHost, State#pgsql_listen_state.amqp) of
        {ok, AMQP} ->
            case dict:find(VHost, AMQP) of
                {ok, {_, Chan}} ->
                    case pgsql_listen_amqp:publish(Chan, X, Channel, Payload, Properties) of
                        ok ->
                            State#pgsql_listen_state{amqp = AMQP};
                        {error, Error} ->
                            rabbit_log:error("pgsql_listen_lib publish error: ~p", [Error]),
                            State
                    end;
                error ->
                    rabbit_log:error("pgsql_listen_lib publish error: missing_amqp_connection"),
                    State
            end;
        {error, Error} ->
            rabbit_log:error("pgsql_listen_lib publish error: ~p", [Error]),
            State
    end.

%% @spec remove_bindings(X, Bs, State) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       Bs     = list90
%%       State  = #pgsql_listen_state
%%       Result = {ok, #pgsql_listen_state}
%% @doc Remove a list of from the exchange
%% @end
%%
remove_bindings(_, [], State) ->
    {ok, State};
remove_bindings(X, [Binding | ListTail], State) ->
    case remove_binding(X, Binding, State) of
        {ok, NewState} -> remove_bindings(X, ListTail, NewState);
        {error, Error} -> {error, Error}
    end.

%% @spec start_exchange(X, State) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       State  = #pgsql_listen_state
%%       Result = {ok, #pgsql_listen_state}|{error, Error}
%% @doc Start and cache references to the pgsql to start the exchange. The
%% RabbitMQ connection will be made on demand.
%%
%% @end
%%
start_exchange(X, State = #pgsql_listen_state{pgsql = PgSQL}) ->
    case ensure_pgsql_connection(X, PgSQL) of
        {ok, NPgSQL} ->
            {ok, State#pgsql_listen_state{pgsql = NPgSQL}};
        {error, Error} ->
            {error, Error}
    end.

%% @spec stop_exchange(X, State) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       State  = #pgsql_listen_state
%%       Result = {ok, #pgsql_listen_state}
%% @doc Stop and remove cache references to the pgsql and rabbitmq processes for
%% an exchange
%% for an exchange
%% @end
%%
stop_exchange(X, State) ->
    stop_pgsql_connection(X, State).

%% @private
%% @spec validate_pgsql_exchange(X) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       Result = ok|{error, Error}
%% @doc Create a new PostgreSQL connection
%% @end
%%
validate_pgsql_connection(X) ->
    case pgsql_listen_db:connect(get_pgsql_dsn(X)) of
        {ok, Conn} ->
            pgsql_listen_db:close(Conn);
        {error, Error} ->
            {error, Error}
    end.

%% ---------------
%% Private Methods
%% ---------------

%% @private
%% @spec ensure_amqp_connection(VHost, AMQP) -> Result
%% @where
%%       VHost  = binary()
%%       AMQP   = dict()
%%       Result = {ok, dict()}|{error, Reason}
%% @doc Ensure that there is an active AMQP connection for the VHost in the
%%      application state
%% @end
%%
ensure_amqp_connection(VHost, AMQP) ->
    case dict:find(VHost, AMQP) of
        {ok, _} ->
            {ok, AMQP};
        error ->
            case pgsql_listen_amqp:open(VHost) of
                {ok, Connection, Channel} ->
                    {ok, dict:store(VHost, {Connection, Channel}, AMQP)};
                {error, {{_, {error, Error}}, _}} ->
                    rabbit_log:info("pgsql_listen_amqp:open/1 error: ~p", [Error]),
                    {error, Error};
                {error, Error} ->
                    rabbit_log:info("pgsql_listen_amqp:open/1 error: ~p", [Error]),
                    {error, Error}
            end
    end.

%% @private
%% @spec ensure_channel_binding_references(Channel, X, Channels) -> Result
%% @where
%%       Channel  = list()
%%       X        = tuple()
%%       Bindings = dict()
%%       Result   = {ok, dict()}|{error, Reason}
%% @doc Ensure that the dict of bindings has one for the given binding key and
%%      that it contains the exchange that the binding key is used on
%% @end
%%
ensure_channel_binding_references(Channel, X, Channels) ->
    case dict:find(Channel, Channels) of
        {ok, Bindings} ->
            case list_find(X, Bindings) of
                true ->
                    {ok, Channels};
                false ->
                    {ok, dict:store(Channel, lists:append(Bindings, [X]), Channels)}
            end;
        error ->
            {ok, dict:store(Channel, [X], Channels)}
    end.

%% @private
%% @spec ensure_pgsql_connection(X, PgSQL) -> Result
%% @where
%%       X       = rabbit_types:exchange()
%%       PgSQL   = dict()
%%       Result = {ok, dict()}|{error, Reason}
%% @doc Ensure that there is an active postgres client connection in the
%%      application state, starting a new connection if not
%% @end
%%
ensure_pgsql_connection(X = #exchange{name = Name}, PgSQL) ->
    case dict:find(Name, PgSQL) of
        {ok, _} ->
            {ok, PgSQL};
        error ->
            DSN = get_pgsql_dsn(X),
            case pgsql_listen_db:connect(DSN) of
                {ok, Conn} ->
                    {ok,
                        dict:store(
                            Name,
                            #pgsql_listen_conn{
                                pid = Conn,
                                server = get_pgsql_server(DSN),
                                dbname = get_pgsql_dbname(DSN)
                            },
                            PgSQL
                        )};
                {error, {{_, {error, Error}}, _}} ->
                    rabbit_log:error('pgsql_listen_lib:ensure_pgsql_connection/2 error: ~p', [Error]),
                    {error, Error};
                {error, {{_, {{_, [{{{_,{error,Error}}, _}, _}]}, _}}, _}} ->
                    rabbit_log:error('pgsql_listen_lib:ensure_pgsql_connection/2 error: ~p', [Error]),
                    {error, Error};
                {error, Error} ->
                    rabbit_log:error('pgsql_listen_lib:ensure_pgsql_connection/2 error: ~p', [Error]),
                    {error, Error}
            end
    end.

%% @private
get_binding_long(Exchange, Channel, Key) ->
    case get_binding_args(Exchange, Channel) of
        {ok, Args} ->
            case lists:keyfind(Key, 1, Args) of
                {_, long, Value} -> Value;
                false -> null;
                _ -> null
            end;
        {err, not_found} ->
            null
    end.

%% @private
get_binding_longstr(Exchange, Channel, Key) ->
    case get_binding_args(Exchange, Channel) of
        {ok, Args} ->
            case lists:keyfind(Key, 1, Args) of
                {_, longstr, Value} -> Value;
                false -> null;
                _ -> null
            end;
        {err, not_found} ->
            null
    end.

%% @private
get_delivery_mode(Exchange, Channel) ->
    case get_binding_args(Exchange, Channel) of
        {ok, Args} ->
            case lists:keyfind(<<"delivery_mode">>, 1, Args) of
                {_, long, Value} when Value >= 1, Value =< 2 -> Value;
                false -> 1;
                _ -> 1
            end;
        {err, not_found} ->
            1
    end.

%% @private
get_binding_args(Exchange, Channel) ->
    Bindings = rabbit_binding:list_for_source(Exchange),
    case lists:keyfind(Channel, #binding.key, Bindings) of
        Binding when is_record(Binding, binding) -> {ok, Binding#binding.args};
        _ -> {err, not_found}
    end.

%% @private
%% @spec get_env(EnvVar, DefaultValue) -> Value
%% @where
%%       Name         = list()
%%       DefaultValue = mixed
%%       Value        = mixed
%% @doc Return the environment variable defined for pgsql_listen returning the
%%      value if the variable is found, otherwise return the passed in default
%% @end
%%
get_env(EnvVar, DefaultValue) ->
    case application:get_env(pgsql_listen, EnvVar) of
        undefined ->
            DefaultValue;
        {ok, V} ->
            V
    end.

%% @private
%% @spec get_parm(X, Name, DefaultValue) -> Value
%% @where
%%       X            = rabbit_types:exchange()
%%       Name         = list()|atom()
%%       DefaultValue = mixed
%%       Value        = mixed
%% @doc Returns the configuration value for an exchange, first by checking to
%% see if a policy value is set for the exchange, then by checking arguments in
%% the exchange, then checking environment defined overrides (config), and
%% finally by returning the passed in default value
%% @end
%%
get_param(X, Name, DefaultValue) when is_atom(Name) ->
    get_param(X, atom_to_list(Name), DefaultValue);
get_param(X = #exchange{arguments = Args}, Name, DefaultValue) when is_list(Name) ->
    case rabbit_policy:get(list_to_binary("pgsql-listen-" ++ Name), X) of
        undefined ->
            get_param_value(Args, Name, DefaultValue);
        Value ->
            case is_binary(Value) of
                true -> binary_to_list(Value);
                false -> Value
            end
    end.

%% @private
%% @spec get_param_env_value(Name, DefaultValue) -> Value
%% @where
%%       Name         = list()
%%       DefaultValue = mixed
%%       Value        = mixed
%% @doc Return the value specified in the config/environment for the passed in
%% key Name, returning DefaultValue if it's not specified
%% @end
%%
get_param_env_value(Name, DefaultValue) ->
    get_env(list_to_atom(Name), DefaultValue).

%% @private
%% @spec get_param_list_value(Value) -> list()
%% @where
%%       DefaultValue = binary()|integer()|list()
%% @doc Cast Value to a list if it is binary or an integer
%% @end
%%
get_param_list_value(Value) when is_binary(Value) ->
    binary_to_list(Value);
get_param_list_value(Value) when is_integer(Value) ->
    integer_to_list(Value);
get_param_list_value(Value) when is_list(Value) ->
    Value.

%% @private
%% @spec get_param_value(Args, Name, DefaultValue) -> Value
%% @where
%%       Args         = rabbit_framing:amqp_table()
%%       Name         = list()
%%       DefaultValue = binary()|integer()|list()
%% @doc Return the value of Name from the Args table, falling back to returning
%% the configuration specified env value, or the DefaultValue if it not present
%% in either Args or the config environment.
%% @end
%%
get_param_value(Args, Name, DefaultValue) ->
    case lists:keyfind(list_to_binary("x-" ++ Name), 1, Args) of
        {_, _, V} -> get_param_list_value(V);
        _ -> get_param_list_value(get_param_env_value(Name, DefaultValue))
    end.

%% @private
%% @spec get_pgsql_dbname(DSN) -> binary()
%% @where
%%       DSN = tuple()#pgsql_listen_dsn
%% @doc Return the database name as a binary
%% @end
%%
get_pgsql_dbname(#pgsql_listen_dsn{dbname = DBName}) ->
    list_to_binary(DBName).

%% @private
%% @spec get_pgsql_dsn(X) -> pgsql_dsn
%% @where
%%       X  = rabbit_types:exchange()
%% @doc Return a pgsql_dsn record for the specified exchange by attempting to
%% first get the value from a policy, falling back to the exchange arguments,
%% then to environment configuration, and finally to the defaults defined in
%% pgsql_listen.hrl
%% @end
%%
get_pgsql_dsn(X) ->
    Host = get_param(X, "host", ?DEFAULT_HOST),
    Port = get_pgsql_port(get_param(X, "port", ?DEFAULT_PORT)),
    User = get_param(X, "user", ?DEFAULT_USER),
    Password = get_param(X, "password", ?DEFAULT_PASSWORD),
    DBName = get_param(X, "dbname", ?DEFAULT_DBNAME),
    #pgsql_listen_dsn{
        host = Host,
        port = Port,
        user = User,
        password = Password,
        dbname = DBName
    }.

%% @private
%% @spec get_pgsql_server(DSN) -> binary()
%% @where
%%       DSN = tuple()#pgsql_listen_dsn
%% @doc Return the formatted server name for the message headers
%% @end
%%
get_pgsql_server(#pgsql_listen_dsn{host = Host, port = Port}) ->
    list_to_binary(lists:flatten([Host, ":", integer_to_list(Port)])).

%% @private
%% @spec get_pgsql_port(Value) -> integer()
%% @where
%%       Value = list()|integer()|none
%% @doc Return the value passed in as an integer if it is a list, the value if
%% it is an integer and the default port of 5432 if it's not a supported type
%% @end
%%
get_pgsql_port(Value) when is_list(Value) ->
    list_to_integer(Value);
get_pgsql_port(Value) when is_number(Value) ->
    Value;
get_pgsql_port(_) ->
    5432.

%% @private
%% @spec is_pgsql_listen_exchange(Exchange) -> Result
%% @where
%%       Exchange = rabbit_types:exchange()
%%       Result   = true|false
%% @doc Returns true if the exchange passed in is a x-pgsql-listen exchange
%% @end
%%
is_pgsql_listen_exchange({exchange, _, 'x-pgsql-listen', _, _, _, _, _, _}) ->
    true;
is_pgsql_listen_exchange(_) ->
    false.

%% @private
%% @spec list_find(Element, List) -> Result
%% @where
%%       Exchange = rabbit_types:exchange()
%%       List     = list()
%%       Result   = true|false
%% @doc Returns true if Element is in List
%% @end
%%
list_find(_, []) ->
    false;
list_find(Element, [Item | ListTail]) ->
    case (Item == Element) of
        true ->
            true;
        false ->
            list_find(Element, ListTail)
    end.

%% @private
%% @spec listen_to_pgsql_channel(Name, Key, PgSQL) -> Result
%% @where
%%       Name   = #exchange.name
%%       Key    = binary()
%%       PgSQL  = dict()
%%       Result = ok|{error, Reason}
%% @doc Issue a LISTEN query to PostgreSQL for the exchange and channel
%% @end
%%
listen_to_pgsql_channel(Name, Key, PgSQL) ->
    case dict:find(Name, PgSQL) of
        {ok, Conn} ->
            pgsql_listen_db:listen(Conn#pgsql_listen_conn.pid, Key);
        error ->
            {error, "pgsql_listen_lib: connection not found"}
    end.

%% @private
%% @spec maybe_close_amqp_connection(X, VHost, Channels, AMQP) -> Result
%% @where
%%       X        = rabbit_term:exchange()
%%       VHost    = binary()
%%       Channels = dict()
%%       AMQP     = dict()
%%       Result   = {ok, dict()}|no_change
%% @doc Close an AMQP connection if there are no pgsql notification channels
%%      listening on the specified channels
%% @end
%%
maybe_close_amqp_connection(X, VHost, Channels, AMQP) ->
    Xs = lists:flatten([dict:fetch(K, Channels) || K <- dict:fetch_keys(Channels)]),
    case [V || {resource, V, _, _} <- Xs, V =:= VHost] of
        [] ->
            stop_amqp_connection(X, VHost, AMQP);
        _ ->
            no_change
    end.

%% @private
%% @spec remove_binding(X, Bs, State) -> Result
%% @where
%%       X       = rabbit_types:exchange()
%%       Binding = rabbit_types:binding()
%%       State   = #pgsql_listen_state
%%       Result  = {ok, #pgsql_listen_state}
%% @doc Remove a binding from the exchange
%% @end
%%
remove_binding(
    X = #exchange{name = Name},
    #binding{key = Key, source = {resource, VHost, exchange, _}},
    State = #pgsql_listen_state{
        amqp = AMQP,
        channels = Cs,
        pgsql = PgSQL
    }
) ->
    case unlisten_to_pgsql_channel(Name, binary_to_list(Key), PgSQL) of
        ok ->
            case remove_channel_binding_reference(binary_to_list(Key), Name, Cs) of
                {ok, NCs} ->
                    case maybe_close_amqp_connection(X, VHost, NCs, AMQP) of
                        no_change ->
                            {ok, State#pgsql_listen_state{channels = NCs}};
                        {ok, NAMQP} ->
                            {ok, State#pgsql_listen_state{amqp = NAMQP, channels = NCs}};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% @private
%% @spec remove_channel_binding_reference(Channel, X, Channels) -> {ok, dict()}
%% @where
%%       Channel  = list()
%%       X        = #exchange.name
%%       Channels = dict()
%% @doc Remove the exchange reference from the bindings for Channel in
%%      the Channels dict
%% @end
%%
remove_channel_binding_reference(Channel, X, Channels) ->
    case dict:find(Channel, Channels) of
        {ok, Bindings} ->
            case list_find(X, Bindings) of
                true ->
                    {ok, dict:store(Channel, lists:delete(X, Bindings), Channels)};
                false ->
                    {ok, Channels}
            end;
        error ->
            {ok, Channels}
    end.

%% @private
%% @spec stop_amqp_connection(X, VHost, AMQP) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       VHost  = binary()
%%       AMQP   = dict()
%%       Result = {ok, dict()}|{error, Reason}
%% @doc Stop a RabbitMQ connection for the specified exchange and remove
%% it from the connection dict *if* there are no other exchanges sharing the
%% connection
%% @end
%%
stop_amqp_connection(X, VHost, AMQP) ->
    case [E || E <- rabbit_exchange:list(VHost), E =/= X, is_pgsql_listen_exchange(X) =:= true] of
        %% No remaining exchanges for vhost but this one
        [] ->
            case dict:find(VHost, AMQP) of
                {ok, {Connection, Channel}} ->
                    ok = pgsql_listen_amqp:close(Connection, Channel),
                    {ok, dict:erase(VHost, AMQP)};
                error ->
                    {ok, AMQP}
            end;
        _ ->
            {ok, AMQP}
    end.

%% @private
%% @spec stop_pgsql_connection(X, State) -> Result
%% @where
%%       X      = rabbit_types:exchange()
%%       Result = ok
%% @doc Stop a PostgreSQL connection for the specified exchange and remove
%% it from the connection dict
%% @end
%%
stop_pgsql_connection(
    #exchange{name = Name},
    State = #pgsql_listen_state{pgsql = PgSQL}
) ->
    case dict:find(Name, PgSQL) of
        {ok, Conn} ->
            ok = pgsql_listen_db:close(Conn#pgsql_listen_conn.pid),
            {ok, State#pgsql_listen_state{pgsql = dict:erase(Name, PgSQL)}};
        {error, Error} ->
            rabbit_log:error(
                "error finding cached connection for ~p in ~p: ~s",
                [Name, PgSQL, Error]
            ),
            {ok, State};
        Other ->
            rabbit_log:info("Other clause matched unexpectedly: ~p", [Other]),
            {ok, State}
    end.

%% @private
%% @spec unlisten_to_pgsql_channel(Name, Key, PgSQL) -> Result
%% @where
%%       Name   = #exchange.name
%%       Key    = binary()
%%       PgSQL  = dict()
%%       Result = ok|{error, Reason}
%% @doc Issue a UNLISTEN query to PostgreSQL for the exchange and channel
%% @end
%%
unlisten_to_pgsql_channel(Name, Key, PgSQL) ->
    case dict:find(Name, PgSQL) of
        {ok, Conn} ->
            pgsql_listen_db:unlisten(Conn#pgsql_listen_conn.pid, Key);
        error ->
            {error, "pgsql_listen_lib: connection not found"}
    end.
