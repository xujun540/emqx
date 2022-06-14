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

-module(emqx_resource).

-include("emqx_resource.hrl").
-include("emqx_resource_utils.hrl").

%% APIs for resource types

-export([list_types/0]).

%% APIs for behaviour implementations

-export([
    query_success/1,
    query_failed/1
]).

%% APIs for instances

-export([
    check_config/2,
    check_and_create/4,
    check_and_create/5,
    check_and_create_local/4,
    check_and_create_local/5,
    check_and_recreate/4,
    check_and_recreate_local/4
]).

%% Sync resource instances and files
%% provisional solution: rpc:multicall to all the nodes for creating/updating/removing
%% todo: replicate operations

%% store the config and start the instance
-export([
    create/4,
    create/5,
    create_local/4,
    create_local/5,
    %% run start/2, health_check/2 and stop/1 sequentially
    create_dry_run/2,
    create_dry_run_local/2,
    %% this will do create_dry_run, stop the old instance and start a new one
    recreate/3,
    recreate/4,
    recreate_local/3,
    recreate_local/4,
    %% remove the config and stop the instance
    remove/1,
    remove_local/1,
    reset_metrics/1,
    reset_metrics_local/1
]).

%% Calls to the callback module with current resource state
%% They also save the state after the call finished (except query/2,3).

%% restart the instance.
-export([
    restart/1,
    restart/2,
    %% verify if the resource is working normally
    health_check/1,
    %% set resource status to disconnected
    set_resource_status_connecting/1,
    %% stop the instance
    stop/1,
    %% query the instance
    query/2,
    %% query the instance with after_query()
    query/3
]).

%% Direct calls to the callback module

%% start the instance
-export([
    call_start/3,
    %% verify if the resource is working normally
    call_health_check/3,
    %% stop the instance
    call_stop/3
]).

%% list all the instances, id only.
-export([
    list_instances/0,
    %% list all the instances
    list_instances_verbose/0,
    %% return the data of the instance
    get_instance/1,
    %% return all the instances of the same resource type
    list_instances_by_type/1,
    generate_id/1,
    list_group_instances/1
]).

-optional_callbacks([
    on_query/4,
    on_get_status/2
]).

%% when calling emqx_resource:start/1
-callback on_start(instance_id(), resource_config()) ->
    {ok, resource_state()} | {error, Reason :: term()}.

%% when calling emqx_resource:stop/1
-callback on_stop(instance_id(), resource_state()) -> term().

%% when calling emqx_resource:query/3
-callback on_query(instance_id(), Request :: term(), after_query(), resource_state()) -> term().

%% when calling emqx_resource:health_check/2
-callback on_get_status(instance_id(), resource_state()) ->
    resource_status()
    | {resource_status(), resource_state()}
    | {resource_status(), resource_state(), term()}.

-spec list_types() -> [module()].
list_types() ->
    discover_resource_mods().

-spec discover_resource_mods() -> [module()].
discover_resource_mods() ->
    [Mod || {Mod, _} <- code:all_loaded(), is_resource_mod(Mod)].

-spec is_resource_mod(module()) -> boolean().
is_resource_mod(Module) ->
    Info = Module:module_info(attributes),
    Behaviour =
        proplists:get_value(behavior, Info, []) ++
            proplists:get_value(behaviour, Info, []),
    lists:member(?MODULE, Behaviour).

-spec query_success(after_query()) -> ok.
query_success(undefined) -> ok;
query_success({OnSucc, _}) -> apply_query_after_calls(OnSucc).

-spec query_failed(after_query()) -> ok.
query_failed(undefined) -> ok;
query_failed({_, OnFailed}) -> apply_query_after_calls(OnFailed).

apply_query_after_calls(Funcs) ->
    lists:foreach(
        fun({Fun, Args}) ->
            safe_apply(Fun, Args)
        end,
        Funcs
    ).

%% =================================================================================
%% APIs for resource instances
%% =================================================================================
-spec create(instance_id(), resource_group(), resource_type(), resource_config()) ->
    {ok, resource_data() | 'already_created'} | {error, Reason :: term()}.
create(InstId, Group, ResourceType, Config) ->
    create(InstId, Group, ResourceType, Config, #{}).

-spec create(instance_id(), resource_group(), resource_type(), resource_config(), create_opts()) ->
    {ok, resource_data() | 'already_created'} | {error, Reason :: term()}.
create(InstId, Group, ResourceType, Config, Opts) ->
    emqx_resource_proto_v1:create(InstId, Group, ResourceType, Config, Opts).
% --------------------------------------------

-spec create_local(instance_id(), resource_group(), resource_type(), resource_config()) ->
    {ok, resource_data() | 'already_created'} | {error, Reason :: term()}.
create_local(InstId, Group, ResourceType, Config) ->
    create_local(InstId, Group, ResourceType, Config, #{}).

-spec create_local(
    instance_id(),
    resource_group(),
    resource_type(),
    resource_config(),
    create_opts()
) ->
    {ok, resource_data()}.
create_local(InstId, Group, ResourceType, Config, Opts) ->
    emqx_resource_manager:ensure_resource(InstId, Group, ResourceType, Config, Opts).

-spec create_dry_run(resource_type(), resource_config()) ->
    ok | {error, Reason :: term()}.
create_dry_run(ResourceType, Config) ->
    emqx_resource_proto_v1:create_dry_run(ResourceType, Config).

-spec create_dry_run_local(resource_type(), resource_config()) ->
    ok | {error, Reason :: term()}.
create_dry_run_local(ResourceType, Config) ->
    emqx_resource_manager:create_dry_run(ResourceType, Config).

-spec recreate(instance_id(), resource_type(), resource_config()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
recreate(InstId, ResourceType, Config) ->
    recreate(InstId, ResourceType, Config, #{}).

-spec recreate(instance_id(), resource_type(), resource_config(), create_opts()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
recreate(InstId, ResourceType, Config, Opts) ->
    emqx_resource_proto_v1:recreate(InstId, ResourceType, Config, Opts).

-spec recreate_local(instance_id(), resource_type(), resource_config()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
recreate_local(InstId, ResourceType, Config) ->
    recreate_local(InstId, ResourceType, Config, #{}).

-spec recreate_local(instance_id(), resource_type(), resource_config(), create_opts()) ->
    {ok, resource_data()} | {error, Reason :: term()}.
recreate_local(InstId, ResourceType, Config, Opts) ->
    emqx_resource_manager:recreate(InstId, ResourceType, Config, Opts).

-spec remove(instance_id()) -> ok | {error, Reason :: term()}.
remove(InstId) ->
    emqx_resource_proto_v1:remove(InstId).

-spec remove_local(instance_id()) -> ok | {error, Reason :: term()}.
remove_local(InstId) ->
    emqx_resource_manager:remove(InstId).

-spec reset_metrics_local(instance_id()) -> ok.
reset_metrics_local(InstId) ->
    emqx_resource_manager:reset_metrics(InstId).

-spec reset_metrics(instance_id()) -> ok | {error, Reason :: term()}.
reset_metrics(InstId) ->
    emqx_resource_proto_v1:reset_metrics(InstId).

%% =================================================================================
-spec query(instance_id(), Request :: term()) -> Result :: term().
query(InstId, Request) ->
    query(InstId, Request, inc_metrics_funcs(InstId)).

%% same to above, also defines what to do when the Module:on_query success or failed
%% it is the duty of the Module to apply the `after_query()` functions.
-spec query(instance_id(), Request :: term(), after_query()) -> Result :: term().
query(InstId, Request, AfterQuery) ->
    case emqx_resource_manager:ets_lookup(InstId) of
        {ok, _Group, #{mod := Mod, state := ResourceState, status := connected}} ->
            %% the resource state is readonly to Module:on_query/4
            %% and the `after_query()` functions should be thread safe
            ok = emqx_metrics_worker:inc(resource_metrics, InstId, matched),
            try
                Mod:on_query(InstId, Request, AfterQuery, ResourceState)
            catch
                Err:Reason:ST ->
                    emqx_metrics_worker:inc(resource_metrics, InstId, exception),
                    erlang:raise(Err, Reason, ST)
            end;
        {ok, _Group, _Data} ->
            query_error(not_found, <<"resource not connected">>);
        {error, not_found} ->
            query_error(not_found, <<"resource not found">>)
    end.

-spec restart(instance_id()) -> ok | {error, Reason :: term()}.
restart(InstId) ->
    restart(InstId, #{}).

-spec restart(instance_id(), create_opts()) -> ok | {error, Reason :: term()}.
restart(InstId, Opts) ->
    emqx_resource_manager:restart(InstId, Opts).

-spec stop(instance_id()) -> ok | {error, Reason :: term()}.
stop(InstId) ->
    emqx_resource_manager:stop(InstId).

-spec health_check(instance_id()) -> {ok, resource_status()} | {error, term()}.
health_check(InstId) ->
    emqx_resource_manager:health_check(InstId).

set_resource_status_connecting(InstId) ->
    emqx_resource_manager:set_resource_status_connecting(InstId).

-spec get_instance(instance_id()) ->
    {ok, resource_group(), resource_data()} | {error, Reason :: term()}.
get_instance(InstId) ->
    emqx_resource_manager:lookup(InstId).

-spec list_instances() -> [instance_id()].
list_instances() ->
    [Id || #{id := Id} <- list_instances_verbose()].

-spec list_instances_verbose() -> [resource_data()].
list_instances_verbose() ->
    emqx_resource_manager:list_all().

-spec list_instances_by_type(module()) -> [instance_id()].
list_instances_by_type(ResourceType) ->
    filter_instances(fun
        (_, RT) when RT =:= ResourceType -> true;
        (_, _) -> false
    end).

-spec generate_id(term()) -> instance_id().
generate_id(Name) when is_binary(Name) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    <<Name/binary, ":", Id/binary>>.

-spec list_group_instances(resource_group()) -> [instance_id()].
list_group_instances(Group) -> emqx_resource_manager:list_group(Group).

-spec call_start(instance_id(), module(), resource_config()) ->
    {ok, resource_state()} | {error, Reason :: term()}.
call_start(InstId, Mod, Config) ->
    ?SAFE_CALL(Mod:on_start(InstId, Config)).

-spec call_health_check(instance_id(), module(), resource_state()) ->
    resource_status()
    | {resource_status(), resource_state()}
    | {resource_status(), resource_state(), term()}.
call_health_check(InstId, Mod, ResourceState) ->
    ?SAFE_CALL(Mod:on_get_status(InstId, ResourceState)).

-spec call_stop(instance_id(), module(), resource_state()) -> term().
call_stop(InstId, Mod, ResourceState) ->
    ?SAFE_CALL(Mod:on_stop(InstId, ResourceState)).

-spec check_config(resource_type(), raw_resource_config()) ->
    {ok, resource_config()} | {error, term()}.
check_config(ResourceType, Conf) ->
    emqx_hocon:check(ResourceType, Conf).

-spec check_and_create(
    instance_id(),
    resource_group(),
    resource_type(),
    raw_resource_config()
) ->
    {ok, resource_data() | 'already_created'} | {error, term()}.
check_and_create(InstId, Group, ResourceType, RawConfig) ->
    check_and_create(InstId, Group, ResourceType, RawConfig, #{}).

-spec check_and_create(
    instance_id(),
    resource_group(),
    resource_type(),
    raw_resource_config(),
    create_opts()
) ->
    {ok, resource_data() | 'already_created'} | {error, term()}.
check_and_create(InstId, Group, ResourceType, RawConfig, Opts) ->
    check_and_do(
        ResourceType,
        RawConfig,
        fun(InstConf) -> create(InstId, Group, ResourceType, InstConf, Opts) end
    ).

-spec check_and_create_local(
    instance_id(),
    resource_group(),
    resource_type(),
    raw_resource_config()
) ->
    {ok, resource_data()} | {error, term()}.
check_and_create_local(InstId, Group, ResourceType, RawConfig) ->
    check_and_create_local(InstId, Group, ResourceType, RawConfig, #{}).

-spec check_and_create_local(
    instance_id(),
    resource_group(),
    resource_type(),
    raw_resource_config(),
    create_opts()
) -> {ok, resource_data()} | {error, term()}.
check_and_create_local(InstId, Group, ResourceType, RawConfig, Opts) ->
    check_and_do(
        ResourceType,
        RawConfig,
        fun(InstConf) -> create_local(InstId, Group, ResourceType, InstConf, Opts) end
    ).

-spec check_and_recreate(
    instance_id(),
    resource_type(),
    raw_resource_config(),
    create_opts()
) ->
    {ok, resource_data()} | {error, term()}.
check_and_recreate(InstId, ResourceType, RawConfig, Opts) ->
    check_and_do(
        ResourceType,
        RawConfig,
        fun(InstConf) -> recreate(InstId, ResourceType, InstConf, Opts) end
    ).

-spec check_and_recreate_local(
    instance_id(),
    resource_type(),
    raw_resource_config(),
    create_opts()
) ->
    {ok, resource_data()} | {error, term()}.
check_and_recreate_local(InstId, ResourceType, RawConfig, Opts) ->
    check_and_do(
        ResourceType,
        RawConfig,
        fun(InstConf) -> recreate_local(InstId, ResourceType, InstConf, Opts) end
    ).

check_and_do(ResourceType, RawConfig, Do) when is_function(Do) ->
    case check_config(ResourceType, RawConfig) of
        {ok, InstConf} -> Do(InstConf);
        Error -> Error
    end.

%% =================================================================================

filter_instances(Filter) ->
    [Id || #{id := Id, mod := Mod} <- list_instances_verbose(), Filter(Id, Mod)].

inc_metrics_funcs(InstId) ->
    OnFailed = [{fun emqx_metrics_worker:inc/3, [resource_metrics, InstId, failed]}],
    OnSucc = [{fun emqx_metrics_worker:inc/3, [resource_metrics, InstId, success]}],
    {OnSucc, OnFailed}.

safe_apply(Func, Args) ->
    ?SAFE_CALL(erlang:apply(Func, Args)).

query_error(Reason, Msg) ->
    {error, {?MODULE, #{reason => Reason, msg => Msg}}}.
