%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authn_test_lib).

-include("emqx_authn.hrl").

-compile(nowarn_export_all).
-compile(export_all).

authenticator_example(Id) ->
    #{Id := #{value := Example}} = emqx_authn_api:authenticator_examples(),
    Example.

http_example() ->
    authenticator_example('password_based:http').

built_in_database_example() ->
    authenticator_example('password_based:built_in_database').

jwt_example() ->
    authenticator_example(jwt).

delete_authenticators(Path, Chain) ->
    case emqx_authentication:list_authenticators(Chain) of
        {error, _} ->
            ok;
        {ok, Authenticators} ->
            lists:foreach(
                fun(#{id := ID}) ->
                    emqx:update_config(
                        Path,
                        {delete_authenticator, Chain, ID},
                        #{rawconf_with_defaults => true}
                    )
                end,
                Authenticators
            )
    end.

delete_config(ID) ->
    {ok, _} =
        emqx:update_config(
            [authentication],
            {delete_authenticator, ?GLOBAL, ID},
            #{rawconf_with_defaults => false}
        ).

client_ssl_cert_opts() ->
    Dir = code:lib_dir(emqx_authn, test),
    #{
        <<"keyfile">> => filename:join([Dir, <<"data/certs">>, <<"client.key">>]),
        <<"certfile">> => filename:join([Dir, <<"data/certs">>, <<"client.crt">>]),
        <<"cacertfile">> => filename:join([Dir, <<"data/certs">>, <<"ca.crt">>])
    }.
