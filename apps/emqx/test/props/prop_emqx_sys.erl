%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(prop_emqx_sys).

-include_lib("proper/include/proper.hrl").

-export([
    initial_state/0,
    command/1,
    precondition/2,
    postcondition/3,
    next_state/3
]).

-define(mock_modules, [
    emqx_metrics,
    emqx_stats,
    emqx_broker,
    mria_mnesia,
    emqx_hooks,
    emqx_config_handler
]).

-define(ALL(Vars, Types, Exprs),
    ?SETUP(
        fun() ->
            State = do_setup(),
            fun() -> do_teardown(State) end
        end,
        ?FORALL(Vars, Types, Exprs)
    )
).

%%--------------------------------------------------------------------
%% Properties
%%--------------------------------------------------------------------

prop_sys() ->
    ?ALL(
        Cmds,
        commands(?MODULE),
        begin
            {ok, _Pid} = emqx_sys:start_link(),
            {History, State, Result} = run_commands(?MODULE, Cmds),
            ok = emqx_sys:stop(),
            ?WHENFAIL(
                io:format(
                    "History: ~p\nState: ~p\nResult: ~p\n",
                    [History, State, Result]
                ),
                aggregate(command_names(Cmds), Result =:= ok)
            )
        end
    ).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

do_setup() ->
    ok = emqx_logger:set_log_level(emergency),
    emqx_config:put([sys_topics, sys_msg_interval], 60000),
    emqx_config:put([sys_topics, sys_heartbeat_interval], 30000),
    emqx_config:put(
        [sys_topics, sys_event_messages],
        #{
            client_connected => true,
            client_disconnected => true,
            client_subscribed => true,
            client_unsubscribed => true
        }
    ),
    [mock(Mod) || Mod <- ?mock_modules],
    ok.

do_teardown(_) ->
    ok = emqx_logger:set_log_level(error),
    [ok = meck:unload(Mod) || Mod <- ?mock_modules],
    ok.

mock(Module) ->
    ok = meck:new(Module, [passthrough, no_history]),
    do_mock(Module).

do_mock(emqx_broker) ->
    meck:expect(
        emqx_broker,
        publish,
        fun(Msg) -> {node(), <<"test">>, Msg} end
    ),
    meck:expect(
        emqx_broker,
        safe_publish,
        fun(Msg) -> {node(), <<"test">>, Msg} end
    );
do_mock(emqx_stats) ->
    meck:expect(emqx_stats, getstats, fun() -> [0] end);
do_mock(mria_mnesia) ->
    meck:expect(mria_mnesia, running_nodes, fun() -> [node()] end);
do_mock(emqx_metrics) ->
    meck:expect(emqx_metrics, all, fun() -> [{hello, 3}] end);
do_mock(emqx_hooks) ->
    meck:expect(emqx_hooks, put, fun(_HookPoint, _MFA, _) -> ok end),
    meck:expect(emqx_hooks, del, fun(_HookPoint, _MF) -> ok end);
do_mock(emqx_config_handler) ->
    meck:expect(emqx_config_handler, add_handler, fun(_, _) -> ok end).

%%--------------------------------------------------------------------
%% MODEL
%%--------------------------------------------------------------------

%% @doc Initial model value at system start. Should be deterministic.
initial_state() ->
    #{}.

%% @doc List of possible commands to run against the system
command(_State) ->
    oneof([
        {call, emqx_sys, info, []},
        {call, emqx_sys, version, []},
        {call, emqx_sys, uptime, []},
        {call, emqx_sys, datetime, []},
        {call, emqx_sys, sysdescr, []},
        %------------ unexpected message ----------------------%
        {call, emqx_sys, handle_call, [emqx_sys, other, state]},
        {call, emqx_sys, handle_cast, [emqx_sys, other]},
        {call, emqx_sys, handle_info, [info, state]}
    ]).

precondition(_State, {call, _Mod, _Fun, _Args}) ->
    true.

postcondition(_State, {call, emqx_sys, info, []}, Info) ->
    is_list(Info) andalso length(Info) =:= 4;
postcondition(_State, {call, emqx_sys, version, []}, Version) ->
    is_list(Version);
postcondition(_State, {call, emqx_sys, uptime, []}, Uptime) ->
    is_integer(Uptime);
postcondition(_State, {call, emqx_sys, datetime, []}, Datetime) ->
    is_list(Datetime);
postcondition(_State, {call, emqx_sys, sysdescr, []}, Sysdescr) ->
    is_list(Sysdescr);
postcondition(_State, {call, emqx_sys, sys_interval, []}, SysInterval) ->
    is_integer(SysInterval) andalso SysInterval > 0;
postcondition(_State, {call, emqx_sys, sys_heartbeat_interval, []}, SysHeartInterval) ->
    is_integer(SysHeartInterval) andalso SysHeartInterval > 0;
postcondition(_State, {call, _Mod, _Fun, _Args}, _Res) ->
    true.

next_state(State, _Res, {call, _Mod, _Fun, _Args}) ->
    NewState = State,
    NewState.
