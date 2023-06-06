%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2014-2020 AWeber Communications
%% @end
%%==============================================================================

%% @doc pgsql-listen exchange plugin implementing core exchange behavior
%% @end

-module(rabbit_exchange_type_pgsql_listen).

-behaviour(rabbit_exchange_type).

-export([
    add_binding/3,
    assert_args_equivalence/2,
    create/2,
    description/0,
    delete/2,
    info/1,
    info/2,
    policy_changed/2,
    recover/2,
    route/2,
    remove_bindings/3,
    serialise_events/0,
    validate/1,
    validate_binding/2
]).

-include("pgsql_listen.hrl").

-rabbit_boot_step(
    {?MODULE, [
        {description, ?EXCHANGE_DESC},
        {mfa, {rabbit_registry, register, [exchange, ?EXCHANGE_TYPE, ?MODULE]}},
        {cleanup, {rabbit_registry, unregister, [exchange, ?EXCHANGE_TYPE]}},
        {requires, pgsql_listen_sup}
    ]}
).

add_binding(transaction, _, _) -> ok;
add_binding(none, X, B) -> gen_server_call({add_binding, X, B}).

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).

create(transaction, _) ->
    ok;
create(none, X) ->
    gen_server_call({create, X}).

description() ->
    [{name, ?EXCHANGE_TYPE}, {description, ?EXCHANGE_DESC}].

% delete(transaction, _, _) -> ok;
delete(none, X) -> gen_server_call({delete, X}).

info(_X) -> [].

info(_X, _) -> [].

policy_changed(OldX, NewX) ->
    Bs = rabbit_binding:list_for_source(OldX),
    case gen_server:call(pgsql_listen_worker, {delete, OldX, Bs}) of
        ok ->
            create(none, NewX);
        Else ->
            Else
    end.

recover(_, _) ->
    ok.

remove_bindings(transaction, _, _) -> ok;
remove_bindings(none, X, Bs) -> gen_server_call({remove_bindings, X, Bs}).

route(X, Delivery) ->
    rabbit_exchange_type_direct:route(X, Delivery).

serialise_events() ->
    false.

validate(X) ->
    gen_server_call({validate, X}).

validate_binding(_X, _B) ->
    ok.

%% @private
%% @spec get_server_call(Args) -> Reply
%% @where
%%       Name         = list()
%%       DefaultValue = mixed
%%       Reply        = ok|{error, Reason}
%% @doc Wrap the gen_server:call behavior to shutdown the channel with an
%%      exception if an error bubbles up from the worker.
%% @end
%%
gen_server_call(Args) ->
    case gen_server:call(pgsql_listen_worker, Args) of
        ok ->
            ok;
        {error, Reason} ->
            rabbit_misc:protocol_error(
                resource_error,
                "pgsql_listen_worker failure (~s)",
                [Reason]
            )
    end.
