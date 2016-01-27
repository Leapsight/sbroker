%%-------------------------------------------------------------------
%%
%% Copyright (c) 2015, James Fish <james@fishcakez.com>
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
%% @doc Implements a head or tail drop queue.
%%
%% `sbroker_drop_queue' can be used as the `sbroker_queue' module in a
%% `sbroker'. Its argument is of the form:
%% ```
%% {out | out_r,  drop | drop_r, Max :: non_neg_integer() | infinity}
%% '''
%% The first element is `out' for a FIFO queue and `out_r' for a LIFO queue. The
%% second element determines whether to drop from head `drop' or drop from the
%% tail `drop_r' when the queue is above the maximum size (third element).
-module(sbroker_drop_queue).

-behaviour(sbroker_queue).

-export([init/3]).
-export([handle_in/5]).
-export([handle_out/2]).
-export([handle_timeout/2]).
-export([handle_cancel/3]).
-export([handle_info/3]).
-export([config_change/3]).
-export([len/1]).
-export([terminate/2]).

-record(state, {out :: out | out_r,
                drop :: drop | drop_r,
                max :: non_neg_integer() | infinity,
                len :: non_neg_integer(),
                queue :: sbroker_queue:internal_queue()}).

%% @private
-spec init(Q, Time, {Out, Drop, Max}) -> {State, infinity} when
      Q :: sbroker_queue:internal_queue(),
      Time :: integer(),
      Out :: out | out_r,
      Drop :: drop | drop_r,
      Max :: non_neg_integer() | infinity,
      State :: #state{}.
init(Q, Time, Arg) ->
    from_queue(Q, queue:len(Q), Time, Arg).

%% @private
-spec handle_in(SendTime, From, Value, Time, State) -> {NState, infinity} when
      SendTime :: integer(),
      From :: {pid(), any()},
      Value :: any(),
      Time :: integer(),
      State :: #state{},
      NState :: #state{}.
handle_in(SendTime, From, _, Time,
          #state{max=Max, len=Max, drop=drop_r} = State) ->
    sbroker_queue:drop(From, SendTime, Time),
    {State, infinity};
handle_in(SendTime, {Pid, _} = From, Value, Time,
          #state{max=Max, len=Max, drop=drop, queue=Q} = State) ->
    {{value, {SendTime2, From2, _, Ref2}}, NQ} = queue:out(Q),
    demonitor(Ref2, [flush]),
    sbroker_queue:drop(From2, SendTime2, Time),
    Ref = monitor(process, Pid),
    NQ2 = queue:in({SendTime, From, Value, Ref}, NQ),
    {State#state{queue=NQ2}, infinity};
handle_in(SendTime, {Pid, _} = From, Value, _,
          #state{len=Len, queue=Q} = State) ->
    Ref = monitor(process, Pid),
    NQ = queue:in({SendTime, From, Value, Ref}, Q),
    {State#state{len=Len+1, queue=NQ}, infinity}.

%% @private
-spec handle_out(Time, State) ->
    {SendTime, From, Value, Ref, NState, infinity} | {empty, NState} when
      Time :: integer(),
      State :: #state{},
      SendTime :: integer(),
      From :: {pid(), any()},
      Value :: any(),
      Ref :: reference(),
      NState :: #state{}.
handle_out(_Time, #state{len=0} = State) ->
    {empty, State};
handle_out(_, #state{out=out, len=Len, queue=Q} = State) ->
    {{value, {SendTime, From, Value, Ref}}, NQ} = queue:out(Q),
    {SendTime, From, Value, Ref, State#state{len=Len-1, queue=NQ}, infinity};
handle_out(_, #state{out=out_r, len=Len, queue=Q} = State) ->
    {{value, {SendTime, From, Value, Ref}}, NQ} = queue:out_r(Q),
    {SendTime, From, Value, Ref, State#state{len=Len-1, queue=NQ}, infinity}.

%% @private
-spec handle_cancel(Tag, Time, State) -> {Cancelled, NState, infinity} when
      Tag :: any(),
      Time :: integer(),
      State :: #state{},
      Cancelled :: false | pos_integer(),
      NState :: #state{}.
handle_cancel(Tag, _, #state{len=Len, queue=Q} = State) ->
    Cancel = fun({_, {_, Tag2}, _, Ref}) when Tag2 =:= Tag ->
                     demonitor(Ref, [flush]),
                     false;
                (_) ->
                     true
             end,
    NQ = queue:filter(Cancel, Q),
    case queue:len(NQ) of
        Len ->
            {false, State, infinity};
        NLen ->
            {Len - NLen, State#state{len=NLen, queue=NQ}, infinity}
    end.

%% @private
-spec handle_timeout(Time, State) -> {State, infinity} when
      Time :: integer(),
      State :: #state{}.
handle_timeout(_Time, State) ->
    {State, infinity}.

%% @private
-spec handle_info(Msg, Time, State) -> {NState, infinity} when
      Msg :: any(),
      Time :: integer(),
      State :: #state{},
      NState :: #state{}.
handle_info({'DOWN', Ref, _, _, _}, _, #state{queue=Q} = State) ->
    NQ = queue:filter(fun({_, _, _, Ref2}) -> Ref2 =/= Ref end, Q),
    {State#state{len=queue:len(NQ), queue=NQ}, infinity};
handle_info(_, _, State) ->
    {State, infinity}.

-spec config_change({Out, Drop, Max}, Time, State) ->
    {NState, infinity} when
      Out :: out | out_r,
      Drop :: drop | drop_r,
      Max :: non_neg_integer() | infinity,
      Time :: integer(),
      State :: #state{},
      NState :: #state{}.
config_change({Out, Drop, infinity}, _, State)
  when (Out =:= out orelse Out =:= out_r) andalso
       (Drop =:= drop orelse Drop =:= drop_r) ->
    {State#state{out=Out, drop=Drop, max=infinity}, infinity};
config_change(Arg, Time, #state{len=Len, queue=Q}) ->
    from_queue(Q, Len, Time, Arg).

%% @private
-spec len(State) -> Len when
      State :: #state{},
      Len :: non_neg_integer().
len(#state{len=Len}) ->
    Len.

%% @private
-spec terminate(Reason, State) -> Q when
      Reason :: any(),
      State :: #state{},
      Q :: sbroker_queue:internal_queue().
terminate(_, #state{queue=Q}) ->
    Q.

%% Internal

from_queue(Q, Len, _, {Out, Drop, infinity})
  when (Out =:= out orelse Out =:= out_r) andalso
       (Drop =:= drop orelse Drop =:= drop_r) ->
    {#state{out=Out, drop=Drop, max=infinity, len=Len, queue=Q}, infinity};
from_queue(Q, Len, Time, {Out, drop, 0}) ->
    from_queue(Q, Len, Time, {Out, drop_r, 0});
from_queue(Q, Len, Time, {Out, Drop, Max})
  when (Out =:= out orelse Out =:= out_r) andalso
       (Drop =:= drop orelse Drop =:= drop_r) andalso
       (is_integer(Max) andalso Max >= 0) ->
    case Len - Max of
        DropCount when DropCount > 0 andalso Drop =:= drop ->
            {DropQ, NQ} = queue:split(DropCount, Q),
            drop_queue(Time, DropQ),
            NState = #state{out=Out, drop=Drop, max=Max, len=Max, queue=NQ},
            {NState, infinity};
        DropCount when DropCount > 0 andalso Drop =:= drop_r ->
            {NQ, DropQ} = queue:split(Max, Q),
            drop_queue(Time, DropQ),
            NState = #state{out=Out, drop=Drop, max=Max, len=Max, queue=NQ},
            {NState, infinity};
        _ ->
            {#state{out=Out, drop=Drop, max=Max, len=Len, queue=Q}, infinity}
    end.

drop_queue(Time, Q) ->
    _ = [drop_item(Time, Item) || Item <- queue:to_list(Q)],
    ok.

drop_item(Time, {SendTime, From, _, Ref}) ->
    demonitor(Ref, [flush]),
    sbroker_queue:drop(From, SendTime, Time).
