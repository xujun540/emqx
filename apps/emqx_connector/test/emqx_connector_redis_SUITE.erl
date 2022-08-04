% %%--------------------------------------------------------------------
% %% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
% %%
% %% Licensed under the Apache License, Version 2.0 (the "License");
% %% you may not use this file except in compliance with the License.
% %% You may obtain a copy of the License at
% %% http://www.apache.org/licenses/LICENSE-2.0
% %%
% %% Unless required by applicable law or agreed to in writing, software
% %% distributed under the License is distributed on an "AS IS" BASIS,
% %% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% %% See the License for the specific language governing permissions and
% %% limitations under the License.
% %%--------------------------------------------------------------------

-module(emqx_connector_redis_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include("emqx_connector.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(REDIS_SINGLE_HOST, "redis").
-define(REDIS_SINGLE_PORT, 6379).
-define(REDIS_SENTINEL_HOST, "redis-sentinel").
-define(REDIS_SENTINEL_PORT, 26379).
-define(REDIS_RESOURCE_MOD, emqx_connector_redis).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_suite(Config) ->
    case
        emqx_common_test_helpers:is_all_tcp_servers_available(
            [
                {?REDIS_SINGLE_HOST, ?REDIS_SINGLE_PORT},
                {?REDIS_SENTINEL_HOST, ?REDIS_SENTINEL_PORT}
            ]
        )
    of
        true ->
            ok = emqx_common_test_helpers:start_apps([emqx_conf]),
            ok = emqx_connector_test_helpers:start_apps([emqx_resource, emqx_connector]),
            Config;
        false ->
            {skip, no_redis}
    end.

end_per_suite(_Config) ->
    ok = emqx_common_test_helpers:stop_apps([emqx_resource, emqx_connector]).

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    ok.

% %%------------------------------------------------------------------------------
% %% Testcases
% %%------------------------------------------------------------------------------

t_single_lifecycle(_Config) ->
    perform_lifecycle_check(
        <<"emqx_connector_redis_SUITE_single">>,
        redis_config_single(),
        [<<"PING">>]
    ).

t_cluster_lifecycle(_Config) ->
    perform_lifecycle_check(
        <<"emqx_connector_redis_SUITE_cluster">>,
        redis_config_cluster(),
        [<<"PING">>, <<"PONG">>]
    ).

t_sentinel_lifecycle(_Config) ->
    perform_lifecycle_check(
        <<"emqx_connector_redis_SUITE_sentinel">>,
        redis_config_sentinel(),
        [<<"PING">>]
    ).

perform_lifecycle_check(PoolName, InitialConfig, RedisCommand) ->
    {ok, #{config := CheckedConfig}} =
        emqx_resource:check_config(?REDIS_RESOURCE_MOD, InitialConfig),
    {ok, #{
        state := #{poolname := ReturnedPoolName} = State,
        status := InitialStatus
    }} = emqx_resource:create_local(
        PoolName,
        ?CONNECTOR_RESOURCE_GROUP,
        ?REDIS_RESOURCE_MOD,
        CheckedConfig,
        #{}
    ),
    ?assertEqual(InitialStatus, connected),
    % Instance should match the state and status of the just started resource
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := InitialStatus
    }} =
        emqx_resource:get_instance(PoolName),
    ?assertEqual({ok, connected}, emqx_resource:health_check(PoolName)),
    % Perform query as further check that the resource is working as expected
    ?assertEqual({ok, <<"PONG">>}, emqx_resource:query(PoolName, {cmd, RedisCommand})),
    ?assertEqual(ok, emqx_resource:stop(PoolName)),
    % Resource will be listed still, but state will be changed and healthcheck will fail
    % as the worker no longer exists.
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{
        state := State,
        status := StoppedStatus
    }} =
        emqx_resource:get_instance(PoolName),
    ?assertEqual(StoppedStatus, disconnected),
    ?assertEqual({error, resource_is_stopped}, emqx_resource:health_check(PoolName)),
    % Resource healthcheck shortcuts things by checking ets. Go deeper by checking pool itself.
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(ReturnedPoolName)),
    % Can call stop/1 again on an already stopped instance
    ?assertEqual(ok, emqx_resource:stop(PoolName)),
    % Make sure it can be restarted and the healthchecks and queries work properly
    ?assertEqual(ok, emqx_resource:restart(PoolName)),
    % async restart, need to wait resource
    timer:sleep(500),
    {ok, ?CONNECTOR_RESOURCE_GROUP, #{status := InitialStatus}} =
        emqx_resource:get_instance(PoolName),
    ?assertEqual({ok, connected}, emqx_resource:health_check(PoolName)),
    ?assertEqual({ok, <<"PONG">>}, emqx_resource:query(PoolName, {cmd, RedisCommand})),
    % Stop and remove the resource in one go.
    ?assertEqual(ok, emqx_resource:remove_local(PoolName)),
    ?assertEqual({error, not_found}, ecpool:stop_sup_pool(ReturnedPoolName)),
    % Should not even be able to get the resource data out of ets now unlike just stopping.
    ?assertEqual({error, not_found}, emqx_resource:get_instance(PoolName)).

% %%------------------------------------------------------------------------------
% %% Helpers
% %%------------------------------------------------------------------------------

redis_config_single() ->
    redis_config_base("single", "server").

redis_config_cluster() ->
    redis_config_base("cluster", "servers").

redis_config_sentinel() ->
    redis_config_base("sentinel", "servers").

-define(REDIS_CONFIG_BASE(MaybeSentinel),
    "" ++
        "\n" ++
        "    auto_reconnect = true\n" ++
        "    database = 1\n" ++
        "    pool_size = 8\n" ++
        "    redis_type = ~s\n" ++
        MaybeSentinel ++
        "    password = public\n" ++
        "    ~s = \"~s:~b\"\n" ++
        "    " ++
        ""
).

redis_config_base(Type, ServerKey) ->
    case Type of
        "sentinel" ->
            Host = ?REDIS_SENTINEL_HOST,
            Port = ?REDIS_SENTINEL_PORT,
            MaybeSentinel = "    sentinel = mymaster\n";
        _ ->
            Host = ?REDIS_SINGLE_HOST,
            Port = ?REDIS_SINGLE_PORT,
            MaybeSentinel = ""
    end,
    RawConfig = list_to_binary(
        io_lib:format(
            ?REDIS_CONFIG_BASE(MaybeSentinel),
            [Type, ServerKey, Host, Port]
        )
    ),

    {ok, Config} = hocon:binary(RawConfig),
    #{<<"config">> => Config}.
