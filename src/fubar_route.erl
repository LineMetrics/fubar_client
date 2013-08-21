%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Routing functions for fubar system.
%%%     This is the core module for fubar's distributed architecture
%%% together with the gateway.
%%%
%%% It governs how the systems work by controlling:
%%%   - how the routing information is stored
%%%   - how the name resolving works
%%%
%%% Created : Nov 16, 2012
%%% -------------------------------------------------------------------
-module(fubar_route).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("sasl_log.hrl").

%% @doc Routing table schema
-record(?MODULE, {name = '_' :: term(),
				  addr = '_' :: undefined | pid(),
				  module = '_' :: module()}).

%%
%% Exports
%%
-export([boot/0, cluster/1, resolve/1, ensure/2, up/2, down/1, clean/1]).

%% @doc Master mode bootstrap logic.
boot() ->
	case mnesia:create_table(?MODULE, [{attributes, record_info(fields, ?MODULE)},
									   {disc_copies, [node()]}, {type, set}]) of
		{atomic, ok} ->
			?INFO({"table created", ?MODULE}),
			ok;
		{aborted, {already_exists, ?MODULE}} ->
			ok
	end,
	ok = mnesia:wait_for_tables([?MODULE], 10000),
	?INFO({"table loaded", ?MODULE}).

%% @doc Slave mode bootstrap logic.
cluster(_MasterNode) ->
	{atomic, ok} = mnesia:add_table_copy(?MODULE, node(), disc_copies),
	?INFO({"table replicated", ?MODULE}).

%% @doc Resovle given name into address.
-spec resolve(term()) -> {ok, {pid(), module()}} | {error, reason()}.
resolve(Name) ->
	case catch mnesia:async_dirty(fun mnesia:dirty_read/2, [?MODULE, Name]) of
		[#?MODULE{name=Name, addr=undefined, module=Module}] ->
			{ok, {undefined, Module}};
		[Route=#?MODULE{name=Name, addr=Addr, module=Module}] ->
			case check_process(Addr) of
				true ->
					{ok, {Addr, Module}};
				_ ->
					{catch mnesia:dirty_write(Route#?MODULE{addr=undefined}), {undefined, Module}}
			end;
		[] ->
			{error, not_found};
		Error ->
			{error, Error}
	end.

%% @doc Ensure given name exists.
-spec ensure(term(), module()) -> {ok, pid()} | {error, reason()}.
ensure(Name, Module) ->
	case catch mnesia:async_dirty(fun mnesia:dirty_read/2, [?MODULE, Name]) of
		[#?MODULE{name=Name, addr=Addr, module=Module}] ->
			case check_process(Addr) of
				true -> {ok, Addr};
				_ -> Module:start([{name, Name}])
			end;
		[#?MODULE{name=Name}] ->
			{error, collision};
		[] ->
			Module:start([{name, Name}]);
		Error ->
			{error, Error}
	end.

%% @doc Update route with fresh name and address.
-spec up(term(), module()) -> ok | {error, reason()}.
up(Name, Module) ->
	Pid = self(),
	Route = #?MODULE{name=Name, addr=Pid, module=Module},
	case catch mnesia:async_dirty(fun mnesia:dirty_read/2, [?MODULE, Name]) of
		[#?MODULE{name=Name, addr=Pid, module=Module}] ->
			% Ignore duplicate up call.
			fubar_log:warning(?MODULE, ["duplicate up", Name, Pid, Module]),
			ok;
		[#?MODULE{name=Name, addr=undefined, module=Module}] ->
			catch mnesia:dirty_write(Route);
		[#?MODULE{name=Name, addr=Addr, module=Module}] ->
			% Oust old one.
			fubar_log:warning(?MODULE, ["conflict up", Name, Pid, Addr, Module]),
			exit(Addr, kill),
			catch mnesia:dirty_write(Route);
		[#?MODULE{name=Name}] ->
			% Occupied by different module.
			{error, collision};
		[] ->
			catch mnesia:dirty_write(Route);
		Error ->
			{error, Error}
	end.

%% @doc Update route with stale name and address.
-spec down(term()) -> ok | {error, reason()}.
down(Name) ->
	case catch mnesia:async_dirty(fun mnesia:dirty_read/2, [?MODULE, Name]) of
		[Route] ->
			catch mnesia:dirty_write(Route#?MODULE{addr=undefined});
		[] ->
			fubar_log:error(?MODULE, ["unknown down", Name]),
			{error, not_found};
		Error ->
			{error, Error}
	end.

%% @doc Delete route.
-spec clean(term()) -> ok | {error, reason()}.
clean(Name) ->
	catch mnesia:dirty_delete(?MODULE, Name).

%%
%% Local
%%		
check_process(undefined) ->
	false;
check_process(Pid) ->
	Local = node(),
	case node(Pid) of
		Local -> % local process
			is_process_alive(Pid);
		Remote -> % remote process
			rpc:call(Remote, erlang, is_process_alive, [Pid])
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.