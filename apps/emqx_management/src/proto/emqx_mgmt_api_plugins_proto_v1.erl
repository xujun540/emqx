%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_mgmt_api_plugins_proto_v1).

-behaviour(emqx_bpapi).

-export([
    introduced_in/0,
    get_plugins/0,
    install_package/2,
    describe_package/1,
    delete_package/1,
    ensure_action/2
]).

-include_lib("emqx/include/bpapi.hrl").

introduced_in() ->
    "5.0.0".

-spec get_plugins() -> emqx_rpc:multicall_result().
get_plugins() ->
    rpc:multicall(emqx_mgmt_api_plugins, get_plugins, [], 15000).

-spec install_package(binary() | string(), binary()) -> emqx_rpc:multicall_result().
install_package(Filename, Bin) ->
    rpc:multicall(emqx_mgmt_api_plugins, install_package, [Filename, Bin], 25000).

-spec describe_package(binary() | string()) -> emqx_rpc:multicall_result().
describe_package(Name) ->
    rpc:multicall(emqx_mgmt_api_plugins, describe_package, [Name], 10000).

-spec delete_package(binary() | string()) -> ok | {error, any()}.
delete_package(Name) ->
    emqx_cluster_rpc:multicall(emqx_mgmt_api_plugins, delete_package, [Name], all, 10000).

-spec ensure_action(binary() | string(), 'restart' | 'start' | 'stop') -> ok | {error, any()}.
ensure_action(Name, Action) ->
    emqx_cluster_rpc:multicall(emqx_mgmt_api_plugins, ensure_action, [Name, Action], all, 10000).
