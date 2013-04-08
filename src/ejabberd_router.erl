%%%----------------------------------------------------------------------
%%% File    : ejabberd_router.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Main router
%%% Created : 27 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_router).

-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([route/3, route_error/4, register_route/1,
	 register_route/2, register_routes/1, unregister_route/1,
	 unregister_routes/1, dirty_get_all_routes/0,
	 dirty_get_all_domains/0, make_id/0, get_domain_balancing/1]).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-type local_hint() :: undefined | integer() | {apply, atom(), atom()}.

-record(route, {domain, pid, local_hint}).

-record(state, {}).

-define(ROUTE_PREFIX, "rr-").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],
			  []).

-spec route(jid(), jid(), xmlel()) -> ok.

route(From, To, Packet) ->
    case catch route_check_id(From, To, Packet) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p~nwhen processing: ~p",
		     [Reason, {From, To, Packet}]);
      _ -> ok
    end.

-spec route_error(jid(), jid(), xmlel(), xmlel()) -> ok.

route_error(From, To, ErrPacket, OrigPacket) ->
    #xmlel{attrs = Attrs} = OrigPacket,
    case <<"error">> == xml:get_attr_s(<<"type">>, Attrs) of
      false -> route(From, To, ErrPacket);
      true -> ok
    end.

-spec register_route(binary()) -> term().

register_route(Domain) ->
    register_route(Domain, undefined).

-spec register_route(binary(), local_hint()) -> term().

register_route(Domain, LocalHint) ->
    case jlib:nameprep(Domain) of
      error -> erlang:error({invalid_domain, Domain});
      LDomain ->
	  Pid = self(),
	  case get_component_number(LDomain) of
	    undefined ->
		F = fun () ->
			    mnesia:write(#route{domain = LDomain, pid = Pid,
						local_hint = LocalHint})
		    end,
		mnesia:transaction(F);
	    N ->
		F = fun () ->
			    case mnesia:wread({route, LDomain}) of
			      [] ->
				  mnesia:write(#route{domain = LDomain,
						      pid = Pid,
						      local_hint = 1}),
				  lists:foreach(fun (I) ->
							mnesia:write(#route{domain
										=
										LDomain,
									    pid
										=
										undefined,
									    local_hint
										=
										I})
						end,
						lists:seq(2, N));
			      Rs ->
				  lists:any(fun (#route{pid = undefined,
							local_hint = I} =
						     R) ->
						    mnesia:write(#route{domain =
									    LDomain,
									pid =
									    Pid,
									local_hint
									    =
									    I}),
						    mnesia:delete_object(R),
						    true;
						(_) -> false
					    end,
					    Rs)
			    end
		    end,
		mnesia:transaction(F)
	  end
    end.

-spec register_routes([binary()]) -> ok.

register_routes(Domains) ->
    lists:foreach(fun (Domain) -> register_route(Domain)
		  end,
		  Domains).

-spec unregister_route(binary()) -> term().

unregister_route(Domain) ->
    case jlib:nameprep(Domain) of
      error -> erlang:error({invalid_domain, Domain});
      LDomain ->
	  Pid = self(),
	  case get_component_number(LDomain) of
	    undefined ->
		F = fun () ->
			    case mnesia:match_object(#route{domain = LDomain,
							    pid = Pid, _ = '_'})
				of
			      [R] -> mnesia:delete_object(R);
			      _ -> ok
			    end
		    end,
		mnesia:transaction(F);
	    _ ->
		F = fun () ->
			    case mnesia:match_object(#route{domain = LDomain,
							    pid = Pid, _ = '_'})
				of
			      [R] ->
				  I = R#route.local_hint,
				  mnesia:write(#route{domain = LDomain,
						      pid = undefined,
						      local_hint = I}),
				  mnesia:delete_object(R);
			      _ -> ok
			    end
		    end,
		mnesia:transaction(F)
	  end
    end.

-spec unregister_routes([binary()]) -> ok.

unregister_routes(Domains) ->
    lists:foreach(fun (Domain) -> unregister_route(Domain)
		  end,
		  Domains).

-spec dirty_get_all_routes() -> [binary()].

dirty_get_all_routes() ->
    lists:usort(mnesia:dirty_all_keys(route)) -- (?MYHOSTS).

-spec dirty_get_all_domains() -> [binary()].

dirty_get_all_domains() ->
    lists:usort(mnesia:dirty_all_keys(route)).

-spec make_id() -> binary().

make_id() ->
    <<?ROUTE_PREFIX, (randoms:get_string())/binary,
      "-", (ejabberd_cluster:node_id())/binary>>.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    update_tables(),
    mnesia:create_table(route,
			[{ram_copies, [node()]}, {type, bag},
			 {attributes, record_info(fields, route)}]),
    mnesia:add_table_copy(route, node(), ram_copies),
    mnesia:subscribe({table, route, simple}),
    lists:foreach(fun (Pid) -> erlang:monitor(process, Pid)
		  end,
		  mnesia:dirty_select(route,
				      [{{route, '_', '$1', '_'}, [], ['$1']}])),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    Reply = ok, {reply, Reply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({route, From, To, Packet}, State) ->
    case catch do_route(From, To, Packet) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p~nwhen processing: ~p",
		     [Reason, {From, To, Packet}]);
      _ -> ok
    end,
    {noreply, State};
handle_info({mnesia_table_event,
	     {write, #route{pid = Pid}, _ActivityId}},
	    State) ->
    erlang:monitor(process, Pid), {noreply, State};
handle_info({'DOWN', _Ref, _Type, Pid, _Info}, State) ->
    F = fun () ->
		Es = mnesia:select(route,
				   [{#route{pid = Pid, _ = '_'}, [], ['$_']}]),
		lists:foreach(fun (E) ->
				      if is_integer(E#route.local_hint) ->
					     LDomain = E#route.domain,
					     I = E#route.local_hint,
					     mnesia:write(#route{domain =
								     LDomain,
								 pid =
								     undefined,
								 local_hint =
								     I}),
					     mnesia:delete_object(E);
					 true -> mnesia:delete_object(E)
				      end
			      end,
			      Es)
	end,
    mnesia:transaction(F),
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

route_check_id(From, To,
	       #xmlel{name = <<"iq">>, attrs = Attrs} = Packet) ->
    case xml:get_attr_s(<<"id">>, Attrs) of
      << ?ROUTE_PREFIX, Rest/binary>> ->
	  Type = xml:get_attr_s(<<"type">>, Attrs),
	  if Type == <<"error">>; Type == <<"result">> ->
		 case str:tokens(Rest, <<"-">>) of
		   [_, NodeID] ->
		       case ejabberd_cluster:get_node_by_id(NodeID) of
			 Node when Node == node() -> do_route(From, To, Packet);
			 Node ->
			     {ejabberd_router, Node} ! {route, From, To, Packet}
		       end;
		   _ -> do_route(From, To, Packet)
		 end;
	     true -> do_route(From, To, Packet)
	  end;
      _ -> do_route(From, To, Packet)
    end;
route_check_id(From, To, Packet) ->
    do_route(From, To, Packet).

do_route(OrigFrom, OrigTo, OrigPacket) ->
    ?DEBUG("route~n\tfrom ~p~n\tto ~p~n\tpacket "
	   "~p~n",
	   [OrigFrom, OrigTo, OrigPacket]),
    case ejabberd_hooks:run_fold(filter_packet,
				 {OrigFrom, OrigTo, OrigPacket}, [])
	of
      {From, To, Packet} ->
	  LDstDomain = To#jid.lserver,
	  case mnesia:dirty_read(route, LDstDomain) of
	    [] -> ejabberd_s2s:route(From, To, Packet);
	    [R] ->
		Pid = R#route.pid,
		if node(Pid) == node() ->
		       case R#route.local_hint of
			 {apply, Module, Function} ->
			     Module:Function(From, To, Packet);
			 _ -> Pid ! {route, From, To, Packet}
		       end;
		   is_pid(Pid) -> Pid ! {route, From, To, Packet};
		   true -> drop
		end;
	    Rs ->
		Value = case get_domain_balancing(LDstDomain) of
                            random -> now();
                            source -> jlib:jid_tolower(From);
                            destination -> jlib:jid_tolower(To);
                            bare_source ->
                                jlib:jid_remove_resource(
                                  jlib:jid_tolower(From));
                            bare_destination ->
                                jlib:jid_remove_resource(
                                  jlib:jid_tolower(To));
                            broadcast ->
                                broadcast
                        end,
		case get_component_number(LDstDomain) of
		  _ when Value == broadcast ->
		      lists:foreach(fun (R) ->
					    Pid = R#route.pid,
					    if is_pid(Pid) ->
						   Pid !
						     {route, From, To, Packet};
					       true -> drop
					    end
				    end,
				    Rs);
		  undefined ->
		      case [R || R <- Rs, node(R#route.pid) == node()] of
			[] ->
			    R = lists:nth(erlang:phash(Value, length(Rs)), Rs),
			    Pid = R#route.pid,
			    if is_pid(Pid) -> Pid ! {route, From, To, Packet};
			       true -> drop
			    end;
			LRs ->
			    R = lists:nth(erlang:phash(Value, length(LRs)),
					  LRs),
			    Pid = R#route.pid,
			    case R#route.local_hint of
			      {apply, Module, Function} ->
				  Module:Function(From, To, Packet);
			      _ -> Pid ! {route, From, To, Packet}
			    end
		      end;
		  _ ->
		      SRs = lists:ukeysort(#route.local_hint, Rs),
		      R = lists:nth(erlang:phash(Value, length(SRs)), SRs),
		      Pid = R#route.pid,
		      if is_pid(Pid) -> Pid ! {route, From, To, Packet};
			 true -> drop
		      end
		end
	  end;
      drop -> ?DEBUG("packet dropped~n", []), ok
    end.

get_component_number(LDomain) ->
    ejabberd_config:get_local_option(
      {domain_balancing_component_number, LDomain},
      fun(N) when is_integer(N), N > 1 -> N end,
      undefined).

get_domain_balancing(LDomain) ->
    ejabberd_config:get_local_option(
      {domain_balancing, LDomain},
      fun(random) -> random;
         (source) -> source;
         (destination) -> destination;
         (bare_source) -> bare_source;
         (bare_destination) -> bare_destination;
         (broadcast) -> broadcast
      end, random).

update_tables() ->
    case catch mnesia:table_info(route, attributes) of
      [domain, node, pid] -> mnesia:delete_table(route);
      [domain, pid] -> mnesia:delete_table(route);
      [domain, pid, local_hint] -> ok;
      {'EXIT', _} -> ok
    end,
    case lists:member(local_route,
		      mnesia:system_info(tables))
	of
      true -> mnesia:delete_table(local_route);
      false -> ok
    end.
