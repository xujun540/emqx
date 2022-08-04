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
-module(emqx_bridge).
-behaviour(emqx_config_handler).
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-export([post_config_update/5]).

-export([
    load_hook/0,
    unload_hook/0
]).

-export([on_message_publish/1]).

-export([
    load/0,
    lookup/1,
    lookup/2,
    lookup/3,
    create/3,
    disable_enable/3,
    remove/2,
    list/0,
    list_bridges_by_connector/1
]).

-export([send_message/2]).

-export([config_key_path/0]).

%% exported for `emqx_telemetry'
-export([get_basic_usage_info/0]).

load() ->
    %% set wait_for_resource_ready => 0 to start resources async
    Opts = #{auto_retry_interval => 60000, wait_for_resource_ready => 0},
    Bridges = emqx:get_config([bridges], #{}),
    lists:foreach(
        fun({Type, NamedConf}) ->
            lists:foreach(
                fun({Name, Conf}) ->
                    safe_load_bridge(Type, Name, Conf, Opts)
                end,
                maps:to_list(NamedConf)
            )
        end,
        maps:to_list(Bridges)
    ).

safe_load_bridge(Type, Name, Conf, Opts) ->
    try
        _Res = emqx_bridge_resource:create(Type, Name, Conf, Opts),
        ?tp(
            emqx_bridge_loaded,
            #{
                type => Type,
                name => Name,
                res => _Res
            }
        )
    catch
        Err:Reason:ST ->
            ?SLOG(error, #{
                msg => "load_bridge_failed",
                type => Type,
                name => Name,
                error => Err,
                reason => Reason,
                stacktrace => ST
            })
    end.

load_hook() ->
    Bridges = emqx:get_config([bridges], #{}),
    load_hook(Bridges).

load_hook(Bridges) ->
    lists:foreach(
        fun({_Type, Bridge}) ->
            lists:foreach(
                fun({_Name, BridgeConf}) ->
                    do_load_hook(BridgeConf)
                end,
                maps:to_list(Bridge)
            )
        end,
        maps:to_list(Bridges)
    ).

do_load_hook(#{local_topic := _} = Conf) ->
    case maps:get(direction, Conf, egress) of
        egress -> emqx_hooks:put('message.publish', {?MODULE, on_message_publish, []}, ?HP_BRIDGE);
        ingress -> ok
    end;
do_load_hook(_Conf) ->
    ok.

unload_hook() ->
    ok = emqx_hooks:del('message.publish', {?MODULE, on_message_publish}).

on_message_publish(Message = #message{topic = Topic, flags = Flags}) ->
    case maps:get(sys, Flags, false) of
        false ->
            {Msg, _} = emqx_rule_events:eventmsg_publish(Message),
            send_to_matched_egress_bridges(Topic, Msg);
        true ->
            ok
    end,
    {ok, Message}.

send_to_matched_egress_bridges(Topic, Msg) ->
    lists:foreach(
        fun(Id) ->
            try send_message(Id, Msg) of
                {error, Reason} ->
                    ?SLOG(error, #{
                        msg => "send_message_to_bridge_failed",
                        bridge => Id,
                        error => Reason
                    });
                _ ->
                    ok
            catch
                Err:Reason:ST ->
                    ?SLOG(error, #{
                        msg => "send_message_to_bridge_exception",
                        bridge => Id,
                        error => Err,
                        reason => Reason,
                        stacktrace => ST
                    })
            end
        end,
        get_matched_bridges(Topic)
    ).

send_message(BridgeId, Message) ->
    {BridgeType, BridgeName} = emqx_bridge_resource:parse_bridge_id(BridgeId),
    ResId = emqx_bridge_resource:resource_id(BridgeType, BridgeName),
    case emqx:get_config([bridges, BridgeType, BridgeName], not_found) of
        not_found ->
            {error, {bridge_not_found, BridgeId}};
        #{enable := true} ->
            emqx_resource:query(ResId, {send_message, Message});
        #{enable := false} ->
            {error, {bridge_stopped, BridgeId}}
    end.

config_key_path() ->
    [bridges].

post_config_update(_, _Req, NewConf, OldConf, _AppEnv) ->
    #{added := Added, removed := Removed, changed := Updated} =
        diff_confs(NewConf, OldConf),
    %% The config update will be failed if any task in `perform_bridge_changes` failed.
    Result = perform_bridge_changes([
        {fun emqx_bridge_resource:remove/3, Removed},
        {fun emqx_bridge_resource:create/3, Added},
        {fun emqx_bridge_resource:update/3, Updated}
    ]),
    ok = unload_hook(),
    ok = load_hook(NewConf),
    Result.

list() ->
    lists:foldl(
        fun({Type, NameAndConf}, Bridges) ->
            lists:foldl(
                fun({Name, RawConf}, Acc) ->
                    case lookup(Type, Name, RawConf) of
                        {error, not_found} -> Acc;
                        {ok, Res} -> [Res | Acc]
                    end
                end,
                Bridges,
                maps:to_list(NameAndConf)
            )
        end,
        [],
        maps:to_list(emqx:get_raw_config([bridges], #{}))
    ).

list_bridges_by_connector(ConnectorId) ->
    [
        B
     || B = #{raw_config := #{<<"connector">> := Id}} <- list(),
        ConnectorId =:= Id
    ].

lookup(Id) ->
    {Type, Name} = emqx_bridge_resource:parse_bridge_id(Id),
    lookup(Type, Name).

lookup(Type, Name) ->
    RawConf = emqx:get_raw_config([bridges, Type, Name], #{}),
    lookup(Type, Name, RawConf).
lookup(Type, Name, RawConf) ->
    case emqx_resource:get_instance(emqx_bridge_resource:resource_id(Type, Name)) of
        {error, not_found} ->
            {error, not_found};
        {ok, _, Data} ->
            {ok, #{
                type => Type,
                name => Name,
                resource_data => Data,
                raw_config => RawConf
            }}
    end.

disable_enable(Action, BridgeType, BridgeName) when
    Action =:= disable; Action =:= enable
->
    emqx_conf:update(
        config_key_path() ++ [BridgeType, BridgeName],
        {Action, BridgeType, BridgeName},
        #{override_to => cluster}
    ).

create(BridgeType, BridgeName, RawConf) ->
    emqx_conf:update(
        emqx_bridge:config_key_path() ++ [BridgeType, BridgeName],
        RawConf,
        #{override_to => cluster}
    ).

remove(BridgeType, BridgeName) ->
    emqx_conf:remove(
        emqx_bridge:config_key_path() ++ [BridgeType, BridgeName],
        #{override_to => cluster}
    ).

%%========================================================================================
%% Helper functions
%%========================================================================================

perform_bridge_changes(Tasks) ->
    perform_bridge_changes(Tasks, ok).

perform_bridge_changes([], Result) ->
    Result;
perform_bridge_changes([{Action, MapConfs} | Tasks], Result0) ->
    Result = maps:fold(
        fun
            ({_Type, _Name}, _Conf, {error, Reason}) ->
                {error, Reason};
            ({Type, Name}, Conf, _) ->
                case Action(Type, Name, Conf) of
                    {error, Reason} -> {error, Reason};
                    Return -> Return
                end
        end,
        Result0,
        MapConfs
    ),
    perform_bridge_changes(Tasks, Result).

diff_confs(NewConfs, OldConfs) ->
    emqx_map_lib:diff_maps(
        flatten_confs(NewConfs),
        flatten_confs(OldConfs)
    ).

flatten_confs(Conf0) ->
    maps:from_list(
        lists:flatmap(
            fun({Type, Conf}) ->
                do_flatten_confs(Type, Conf)
            end,
            maps:to_list(Conf0)
        )
    ).

do_flatten_confs(Type, Conf0) ->
    [{{Type, Name}, Conf} || {Name, Conf} <- maps:to_list(Conf0)].

get_matched_bridges(Topic) ->
    Bridges = emqx:get_config([bridges], #{}),
    maps:fold(
        fun(BType, Conf, Acc0) ->
            maps:fold(
                fun
                    %% Confs for MQTT, Kafka bridges have the `direction` flag
                    (_BName, #{direction := ingress}, Acc1) ->
                        Acc1;
                    (BName, #{direction := egress} = Egress, Acc1) ->
                        %% WebHook, MySQL bridges only have egress direction
                        get_matched_bridge_id(Egress, Topic, BType, BName, Acc1)
                end,
                Acc0,
                Conf
            )
        end,
        [],
        Bridges
    ).

get_matched_bridge_id(#{enable := false}, _Topic, _BType, _BName, Acc) ->
    Acc;
get_matched_bridge_id(#{local_topic := Filter}, Topic, BType, BName, Acc) ->
    case emqx_topic:match(Topic, Filter) of
        true -> [emqx_bridge_resource:bridge_id(BType, BName) | Acc];
        false -> Acc
    end.

-spec get_basic_usage_info() ->
    #{
        num_bridges => non_neg_integer(),
        count_by_type =>
            #{BridgeType => non_neg_integer()}
    }
when
    BridgeType :: atom().
get_basic_usage_info() ->
    InitialAcc = #{num_bridges => 0, count_by_type => #{}},
    try
        lists:foldl(
            fun
                (#{resource_data := #{config := #{enable := false}}}, Acc) ->
                    Acc;
                (#{type := BridgeType}, Acc) ->
                    NumBridges = maps:get(num_bridges, Acc),
                    CountByType0 = maps:get(count_by_type, Acc),
                    CountByType = maps:update_with(
                        binary_to_atom(BridgeType, utf8),
                        fun(X) -> X + 1 end,
                        1,
                        CountByType0
                    ),
                    Acc#{
                        num_bridges => NumBridges + 1,
                        count_by_type => CountByType
                    }
            end,
            InitialAcc,
            list()
        )
    catch
        %% for instance, when the bridge app is not ready yet.
        _:_ ->
            InitialAcc
    end.
